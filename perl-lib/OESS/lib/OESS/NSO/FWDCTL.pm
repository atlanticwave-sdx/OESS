package OESS::NSO::FWDCTL;

use AnyEvent;
use Data::Dumper;
use GRNOC::RabbitMQ::Method;
use GRNOC::WebService::Regex;
use HTTP::Request::Common;
use JSON;
use Log::Log4perl;
use LWP::UserAgent;
use XML::LibXML;

use OESS::Config;
use OESS::DB;
use OESS::DB::Circuit;
use OESS::DB::Node;
use OESS::DB::VRF;
use OESS::L2Circuit;
use OESS::Node;
use OESS::NSO::Client;
use OESS::RabbitMQ::Dispatcher;
use OESS::VRF;

use constant FWDCTL_WAITING     => 2;
use constant FWDCTL_SUCCESS     => 1;
use constant FWDCTL_FAILURE     => 0;
use constant FWDCTL_UNKNOWN     => 3;
use constant FWDCTL_BLOCKED     => 4;

use constant PENDING_DIFF_NONE  => 0;
use constant PENDING_DIFF       => 1;
use constant PENDING_DIFF_ERROR => 2;
use constant PENDING_DIFF_APPROVED => 3;

=head1 OESS::NSO::FWDCTL

=cut

=head2 new

=cut
sub new {
    my $class = shift;
    my $args  = {
        connection_cache => undef, # OESS::NSO::ConnectionCache
        config           => '/etc/oess/database.xml',
        config_obj       => undef, # OESS::Config
        db               => undef, # OESS::DB
        nso              => undef, # OESS::NSO::Client or OESS::NSO::ClientStub
        logger           => Log::Log4perl->get_logger('OESS.NSO.FWDCTL'),
        @_
    };
    my $self = bless $args, $class;

    if (!defined $self->{config_obj}) {
        $self->{config_obj} = new OESS::Config(config_filename => $self->{config_filename});
    }

    $self->{pending_diff} = {};
    $self->{nodes} = {};

    return $self;
}

=head2 addVlan

=cut
sub addVlan {
    my $self = shift;
    my $args = {
        circuit_id => undef,
        @_
    };

    my $conn = new OESS::L2Circuit(
        db => $self->{db},
        circuit_id => $args->{circuit_id}
    );
    $conn->load_endpoints;

    my $err = $self->{nso}->create_l2connection($conn);
    return $err if (defined $err);

    $self->{connection_cache}->add_connection($conn, 'l2');
    return;
}

=head2 deleteVlan

=cut
sub deleteVlan {
    my $self = shift;
    my $args = {
        circuit_id => undef,
        @_
    };

    my $conn = new OESS::L2Circuit(
        db => $self->{db},
        circuit_id => $args->{circuit_id}
    );
    return "Couldn't find l3connection $args->{vrf_id}." if !defined $conn;
    $conn->load_endpoints;

    my $err = $self->{nso}->delete_l2connection($args->{circuit_id});
    return $err if (defined $err);

    $self->{connection_cache}->remove_connection($conn, 'l2');
    return;
}

=head2 modifyVlan

=cut
sub modifyVlan {
    my $self = shift;
    my $args = {
        pending => undef,
        @_
    };

    my $pending_hash = decode_json($args->{pending});
    my $pending_conn = new OESS::L2Circuit(db => $self->{db}, model => $pending_hash);

    my $err = $self->{nso}->edit_l2connection($pending_conn);
    return $err if (defined $err);

    $self->{connection_cache}->add_connection($pending_conn, 'l2');
    return;
}

=head2 addVrf

=cut
sub addVrf {
    my $self = shift;
    my $args = {
        vrf_id => undef,
        @_
    };

    my $conn = new OESS::VRF(
        db     => $self->{db},
        vrf_id => $args->{vrf_id}
    );
    return "Couldn't find l3connection $args->{vrf_id}." if !defined $conn;

    $conn->load_endpoints;
    foreach my $ep (@{$conn->endpoints}) {
        $ep->load_peers;
    }

    my $err = $self->{nso}->create_l3connection($conn);
    return $err if (defined $err);

    $self->{connection_cache}->add_connection($conn, 'l3');
    return;
}

=head2 deleteVrf

=cut
sub deleteVrf {
    my $self = shift;
    my $args = {
        vrf_id => undef,
        @_
    };

    my $conn = new OESS::VRF(
        db => $self->{db},
        vrf_id => $args->{vrf_id}
    );
    return "Couldn't find l3connection $args->{vrf_id}." if !defined $conn;
    $conn->load_endpoints;

    my $err = $self->{nso}->delete_l3connection($args->{vrf_id});
    return $err if (defined $err);

    $self->{connection_cache}->remove_connection($conn, 'l3');
    return;
}

=head2 modifyVrf

=cut
sub modifyVrf {
    my $self   = shift;
    my $args = {
        pending => undef,
        @_
    };

    my $pending_hash = decode_json($args->{pending});
    my $pending_conn = new OESS::VRF(db => $self->{db}, model => $pending_hash);
    $pending_conn->{endpoints} = [];
    foreach my $pending_ep_hash (@{$pending_hash->{endpoints}}) {
        my $pending_ep = new OESS::Endpoint(db => $self->{db}, model => $pending_ep_hash);

        $pending_ep->{peers} = [];
        foreach my $pending_peer_hash (@{$pending_ep_hash->{peers}}) {
            push @{$pending_ep->{peers}}, new OESS::Peer(db => $self->{db}, model => $pending_peer_hash);
        }
        push @{$pending_conn->{endpoints}}, $pending_ep;
    }

    my $err = $self->{nso}->edit_l3connection($pending_conn);
    return $err if (defined $err);

    $self->{connection_cache}->add_connection($pending_conn, 'l3');
    return;
}

=head2 diff

diff reads all connections from cache, loads all connections from nso,
determines if a configuration change within nso is required, and if so, make
the change.

In the case of a large change (effects > N connections), the diff is put
into a pending state. Diff states are tracked on a per-node basis.

=cut
sub diff {
    my $self = shift;

    my ($raw_l2connections, $err) = $self->{nso}->get_l2connections();
    return $err if defined $err;

    # After a connection has been sync'd to NSO we remove it from our hash of
    # nso connections. Any connections left in this hash after syncing are not
    # known by OESS and should be removed.
    my $nso_l2connections = {};
    foreach my $conn (@{$raw_l2connections}) {
        $nso_l2connections->{$conn->{connection_id}} = $conn;
    }

    my ($raw_l3connections, $err) = $self->{nso}->get_l3connections();
    return $err if defined $err;

    my $nso_l3connections = {};
    foreach my $conn (@{$raw_l3connections}) {
        $nso_l3connections->{$conn->{connection_id}} = $conn;
    }

    my $network_diff = {};
    my $changes = [];

    # Connections are stored in-memory multiple times under each node they're
    # associed with. Keep a record of connections as they're sync'd to prevent a
    # connection from being sync'd more than once.
    my $syncd_connections = {};

    # Needed to ensure diff state may be set to PENDING_DIFF_NONE after approval
    my $all_nodes = OESS::DB::Node::fetch_all(db => $self->{db}, controller => 'nso');
    foreach my $node (@$all_nodes) {
        $network_diff->{$node->{name}} = "";
    }

    foreach my $node_hash (@$all_nodes) {
        my $node_id = $node_hash->{node_id};

        foreach my $conn (@{$self->{connection_cache}->get_connections_by_node($node_id, 'l2')}) {
            # Skip connections if they're already sync'd.
            next if defined $syncd_connections->{$conn->circuit_id};
            $syncd_connections->{$conn->circuit_id} = 1;

            # Compare cached connection against NSO connection. If no difference
            # continue with next connection, otherwise update NSO to align with
            # cache.
            my $diff_required = 0;

            my $diff = $conn->nso_diff($nso_l2connections->{$conn->circuit_id});
            foreach my $node (keys %$diff) {
                next if $diff->{$node} eq "";

                $diff_required = 1;
                $network_diff->{$node} .= $diff->{$node};
            }

            if (!defined $nso_l2connections->{$conn->circuit_id}) {
                push(@$changes, { type => 'create-l2connection', value => $conn }) if $diff_required;
                next;
            }

            push(@$changes, { type => 'edit-l2connection', value => $conn }) if $diff_required;
            delete $nso_l2connections->{$conn->circuit_id};
        }

        foreach my $conn (@{$self->{connection_cache}->get_connections_by_node($node_id, 'l3')}) {
            # Skip connections if they're already sync'd.
            next if defined $syncd_connections->{$conn->vrf_id};
            $syncd_connections->{$conn->vrf_id} = 1;

            # Compare cached connection against NSO connection. If no difference
            # continue with next connection, otherwise update NSO to align with
            # cache.
            my $diff_required = 0;

            my $diff = $conn->nso_diff($nso_l3connections->{$conn->vrf_id});
            foreach my $node (keys %$diff) {
                next if $diff->{$node} eq "";

                $diff_required = 1;
                $network_diff->{$node} .= $diff->{$node};
            }

            if (!defined $nso_l3connections->{$conn->vrf_id}) {
                push(@$changes, { type => 'create-l3connection', value => $conn }) if $diff_required;
                next;
            }

            push(@$changes, { type => 'edit-l3connection', value => $conn }) if $diff_required;
            delete $nso_l3connections->{$conn->vrf_id};
        }
    }

    my $empty_conn = new OESS::L2Circuit(db => $self->{db}, model => {});
    foreach my $conn_id (keys %{$nso_l2connections}) {
        my $diff = $empty_conn->nso_diff($nso_l2connections->{$conn_id});
        foreach my $node (keys %$diff) {
            next if $diff->{$node} eq "";

            $diff_required = 1;
            $network_diff->{$node} .= $diff->{$node};
        }

        push @$changes, { type => 'delete-l2connection', value => $nso_l2connections->{$conn_id} };
    }

    my $empty_conn = new OESS::VRF(db => $self->{db}, model => {});
    foreach my $conn_id (keys %{$nso_l3connections}) {
        my $diff = $empty_conn->nso_diff($nso_l3connections->{$conn_id});
        foreach my $node (keys %$diff) {
            next if $diff->{$node} eq "";

            $diff_required = 1;
            $network_diff->{$node} .= $diff->{$node};
        }

        push @$changes, { type => 'delete-l3connection', value => $nso_l3connections->{$conn_id} };
    }

    # TODO Retain manually approved diff state between diffs

    # If the database asserts there is no diff pending but memory
    # disagrees, then the pending state was modified by an admin. The
    # pending diff may now proceed.
    foreach my $node_name (keys %$network_diff) {
        my $node = new OESS::Node(db => $self->{db}, name => $node_name);
        my $diff_len = length $network_diff->{$node_name};

        if ($diff_len < 30) {
            $self->{pending_diff}->{$node_name} = PENDING_DIFF_NONE;
            $node->pending_diff(PENDING_DIFF_NONE);
            $node->update;
            $self->{logger}->info("Applying network diff. No approval required for $node_name.") if $diff_len > 0;
        } else {
            if ($self->{pending_diff}->{$node_name} == PENDING_DIFF_NONE) {
                $self->{pending_diff}->{$node_name} = PENDING_DIFF;
                $node->pending_diff(PENDING_DIFF);
                $node->update;
                $self->{logger}->info("Not applying network diff. Manual approval required for $node_name.");
            }

            if ($self->{pending_diff}->{$node_name} == PENDING_DIFF && $node->pending_diff == PENDING_DIFF_NONE) {
                $self->{pending_diff}->{$node_name} = PENDING_DIFF_APPROVED;
                $self->{logger}->info("Applying network diff. Manual approval granted for $node_name.");
            }
        }

        $self->{logger}->debug("Diff for $node_name has length of $diff_len:\n$network_diff->{$node_name}");
    }
    $self->{logger}->debug('Changes: ' . Dumper($changes));

    foreach my $change (@$changes) {
        if ($change->{type} eq 'create-l2connection') {
            my $conn = $change->{value};

            # If conn endpoint on node with a blocked diff skip
            my $diff_approval_required = 0;
            foreach my $ep (@{$conn->endpoints}) {
                if ($self->{pending_diff}->{$ep->node} == PENDING_DIFF) {
                    $diff_approval_required =  1;
                    last;
                }
            }
            if ($diff_approval_required) {
                $self->{logger}->info("Not applying l2connection $conn->{circuit_id}. Manual approval required.");
                next;
            }

            my $err = $self->{nso}->create_l2connection($conn);
            if (defined $err) {
                $self->{logger}->error($err);
            }
            $self->{logger}->info("Applied l2connection $conn->{circuit_id}.");
        }
        elsif ($change->{type} eq 'edit-l2connection') {
            my $conn = $change->{value};

            # If conn endpoint on node with a blocked diff skip
            my $diff_approval_required = 0;
            foreach my $ep (@{$conn->endpoints}) {
                if ($self->{pending_diff}->{$ep->node} == PENDING_DIFF) {
                    $diff_approval_required =  1;
                    last;
                }
            }
            if ($diff_approval_required) {
                warn "Not syncing l2connection $conn->{circuit_id}. Diff approval required.";
                next;
            }

            my $err = $self->{nso}->edit_l2connection($conn);
            if (defined $err) {
                $self->{logger}->error($err);
            }
            $self->{logger}->info("Sync'd l2connection $conn->{circuit_id}.");
        }
        elsif ($change->{type} eq 'delete-l2connection') {
            my $conn = $change->{value};

            # If conn endpoint on node with a blocked diff skip
            my $diff_approval_required = 0;
            foreach my $ep (@{$conn->{endpoint}}) {
                if ($self->{pending_diff}->{$ep->{device}} == PENDING_DIFF) {
                    $diff_approval_required =  1;
                    last;
                }
            }
            if ($diff_approval_required) {
                warn "Not syncing l2connection $conn->{circuit_id}. Diff approval required.";
                next;
            }

            my $err = $self->{nso}->delete_l2connection($conn->{connection_id});
            if (defined $err) {
                $self->{logger}->error($err);
            }
        }
        elsif ($change->{type} eq 'create-l3connection') {
            my $conn = $change->{value};

            # If conn endpoint on node with a blocked diff skip
            my $diff_approval_required = 0;
            foreach my $ep (@{$conn->endpoints}) {
                if ($self->{pending_diff}->{$ep->node} == PENDING_DIFF) {
                    $diff_approval_required =  1;
                    last;
                }
            }
            if ($diff_approval_required) {
                warn "Not syncing l3connection $conn->{vrf_id}. Diff approval required.";
                next;
            }

            my $err = $self->{nso}->create_l3connection($conn);
            if (defined $err) {
                $self->{logger}->error($err);
            }
            $self->{logger}->info("Sync'd l3connection $conn->{vrf_id}.");
        }
        elsif ($change->{type} eq 'edit-l3connection') {
            my $conn = $change->{value};

            # If conn endpoint on node with a blocked diff skip
            my $diff_approval_required = 0;
            foreach my $ep (@{$conn->endpoints}) {
                if ($self->{pending_diff}->{$ep->node} == PENDING_DIFF) {
                    $diff_approval_required =  1;
                    last;
                }
            }
            if ($diff_approval_required) {
                warn "Not syncing l3connection $conn->{vrf_id}. Diff approval required.";
                next;
            }

            my $err = $self->{nso}->edit_l3connection($conn);
            if (defined $err) {
                $self->{logger}->error($err);
            }
            $self->{logger}->info("Sync'd l3connection $conn->{vrf_id}.");
        }
        elsif ($change->{type} eq 'delete-l3connection') {
            my $conn = $change->{value};

            # If conn endpoint on node with a blocked diff skip
            my $diff_approval_required = 0;
            foreach my $ep (@{$conn->{endpoint}}) {
                if ($self->{pending_diff}->{$ep->{device}} == PENDING_DIFF) {
                    $diff_approval_required =  1;
                    last;
                }
            }
            if ($diff_approval_required) {
                warn "Not syncing l3connection $conn->{vrf_id}. Diff approval required.";
                next;
            }

            my $err = $self->{nso}->delete_l3connection($conn->{connection_id});
            if (defined $err) {
                $self->{logger}->error($err);
            }
        }
        else {
            warn 'no idea what happened here';
        }
    }

    return;
}

=head2 get_diff_text

=cut
sub get_diff_text {
    my $self = shift;
    my $args = {
        node_id   => undef,
        node_name => undef,
        @_
    };

    my $node_id = $args->{node_id};
    my $node_name = "";

    my ($l2_connections, $err1) = $self->{nso}->get_l2connections();
    if (defined $err1) {
        return (undef, $err1);
    }
    my ($l3_connections, $err2) = $self->{nso}->get_l3connections();
    if (defined $err2) {
        return (undef, $err2);
    }

    # After a connection has been sync'd to NSO we remove it from our hash of
    # nso connections. Any connections left in this hash after syncing are not
    # known by OESS and should be removed.
    my $nso_l2connections = {};
    foreach my $conn (@{$l2_connections}) {
        $nso_l2connections->{$conn->{connection_id}} = $conn;
    }
    my $nso_l3connections = {};
    foreach my $conn (@{$l3_connections}) {
        $nso_l3connections->{$conn->{connection_id}} = $conn;
    }

    my $network_diff = {};
    my $changes = [];

    # Connections are stored in-memory multiple times under each node
    # they're associed with. Keep a record of connections as they're
    # sync'd to prevent a connection from being sync'd more than once.
    my $syncd_l2connections = {};
    my $syncd_l3connections = {};


    # Ensure that requested node is represented in hash and that name
    # is looked up. This is needed to ensure diff state may be set to
    # PENDING_DIFF_NONE after approval
    my $all_nodes = OESS::DB::Node::fetch_all(db => $self->{db}, controller => 'nso');
    foreach my $node (@$all_nodes) {
        if ($node->{node_id} eq $node_id) {
            $node_name = $node->{name};
        }
        $network_diff->{$node->{name}} = "";
    }

    foreach my $node (@$all_nodes) {
        my $node_id = $node->{node_id};

        foreach my $conn (@{$self->{connection_cache}->get_connections_by_node($node_id, 'l2')}) {

            # Skip connections if they're already sync'd.
            next if defined $syncd_l2connections->{$conn->circuit_id};
            $syncd_l2connections->{$conn->circuit_id} = 1;

            # Compare cached connection against NSO connection. If no
            # difference continue with next connection, otherwise
            # update NSO to align with cache.
            my $diff_required = 0;

            my $diff = $conn->nso_diff($nso_l2connections->{$conn->circuit_id});
            foreach my $node (keys %$diff) {
                next if $diff->{$node} eq "";

                $diff_required = 1;
                $network_diff->{$node} .= $diff->{$node};
            }

            if (!defined $nso_l2connections->{$conn->circuit_id}) {
                push(@$changes, { type => 'create-l2connection', value => $conn }) if $diff_required;
                next;
            }

            push(@$changes, { type => 'edit-l2connection', value => $conn->circuit_id }) if $diff_required;
            delete $nso_l2connections->{$conn->circuit_id};
        }

        foreach my $conn (@{$self->{connection_cache}->get_connections_by_node($node_id, 'l3')}) {

            # Skip connections if they're already sync'd.
            next if defined $syncd_l3connections->{$conn->vrf_id};
            $syncd_l3connections->{$conn->vrf_id} = 1;

            # Compare cached connection against NSO connection. If no difference
            # continue with next connection, otherwise update NSO to align with
            # cache.
            my $diff_required = 0;

            my $diff = $conn->nso_diff($nso_l3connections->{$conn->vrf_id});
            foreach my $node (keys %$diff) {
                next if $diff->{$node} eq "";

                $diff_required = 1;
                $network_diff->{$node} .= $diff->{$node};
            }

            if (!defined $nso_l3connections->{$conn->vrf_id}) {
                push(@$changes, { type => 'create-l3connection', value => $conn }) if $diff_required;
                next;
            }

            push(@$changes, { type => 'edit-l3connection', value => $conn->vrf_id }) if $diff_required;
            delete $nso_l3connections->{$conn->vrf_id};
        }
    }

    my $empty_conn1 = new OESS::L2Circuit(db => $self->{db}, model => {});
    foreach my $conn_id (keys %{$nso_l2connections}) {
        my $diff = $empty_conn1->nso_diff($nso_l2connections->{$conn_id});
        foreach my $node (keys %$diff) {
            next if $diff->{$node} eq "";

            $diff_required = 1;
            $network_diff->{$node} .= $diff->{$node};
        }

        push @$changes, { type => 'delete-l2connection', value => $conn_id };
    }

    my $empty_conn2 = new OESS::VRF(db => $self->{db}, model => {});
    foreach my $conn_id (keys %{$nso_l3connections}) {
        my $diff = $empty_conn2->nso_diff($nso_l3connections->{$conn_id});
        foreach my $node (keys %$diff) {
            next if $diff->{$node} eq "";

            $diff_required = 1;
            $network_diff->{$node} .= $diff->{$node};
        }

        push @$changes, { type => 'delete-l2connection', value => $conn_id };
    }

    if (defined $args->{node_name}) {
        $node_name = $args->{node_name};
    }

    $self->{logger}->debug('Requested diff text: ' . $network_diff->{$node_name});
    return ($network_diff->{$node_name}, undef);
}

=head2 new_switch

=cut
sub new_switch {
    my $self = shift;
    my $args = {
        node_id => undef,
        @_
    };
    my $method = shift;
    my $params = shift;

    my $success = $method->{'success_callback'};
    my $error   = $method->{'error_callback'};

    if (defined $self->{nodes}->{$args->{node_id}}) {
        $self->{logger}->warn("Node $args->{node_id} already registered with FWDCTL.");
        return;
    }

    my $node = OESS::DB::Node::fetch(db => $self->{db}, node_id => $args->{node_id});
    if (!defined $node) {
        return "Couldn't lookup node $args->{node_id}. FWDCTL will not properly provision on this node.";
    }
    $self->{nodes}->{$args->{node_id}} = $node;

    warn "Switch $node->{name} registered with FWDCTL.";
    $self->{logger}->info("Switch $node->{name} registered with FWDCTL.");

    # Make first invocation of polling subroutines
    $self->diff;
    return;
}

=head2 update_cache

update_cache reads all connections from the database and loads them
into an in-memory cache.

=cut
sub update_cache {
    my $self   = shift;

    $self->{connection_cache}->clear;

    my $l2connections = OESS::DB::Circuit::fetch_circuits(
        db => $self->{db},
        state => 'active'
    );
    if (!defined $l2connections) {
        $self->{logger}->error("Couldn't load l2connections in update_cache.");
        return "Couldn't load l2connections in update_cache.";
    }

    foreach my $conn (@$l2connections) {
        my $obj = new OESS::L2Circuit(db => $self->{db}, model => $conn);
        $obj->load_endpoints;
        $self->{connection_cache}->add_connection($obj, 'l2');
    }

    my $l3connection_ids = OESS::DB::VRF::get_vrfs(
        db => $self->{db},
        state => 'active'
    );
    if (!defined $l3connection_ids) {
        $self->{logger}->error("Couldn't load l3connections in update_cache.");
        return "Couldn't load l3connections in update_cache.";
    }

    foreach my $conn (@$l3connection_ids) {
        my $obj = new OESS::VRF(db => $self->{db}, vrf_id => $conn->{vrf_id});
        $obj->load_endpoints;

        foreach my $ep (@{$obj->endpoints}) {
            $ep->load_peers;
        }
        $self->{connection_cache}->add_connection($obj, 'l3');
    }
    return;
}

=head2 update_nodes

update_nodes reads all nodes from the database and loads them into an
in-memory cache similar to update_cache.

=cut
sub update_nodes {
    my $self = shift;

    my $nodes = OESS::DB::Node::fetch_all(db => $self->{db}, controller => 'nso');
    if (!defined $nodes) {
        return "Couldn't lookup nodes. FWDCTL will not provision on any existing nodes.";
    }
    foreach my $node (@$nodes) {
        $self->{nodes}->{$node->{node_id}} = $node;
    }

    return;
}

1;
