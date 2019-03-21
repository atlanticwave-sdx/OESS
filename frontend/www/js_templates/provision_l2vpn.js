class GlobalState extends Component {
  constructor(state) {
    super();
    this.circuit = {
      circuit_id: -1,
      endpoints:  [],
      static_mac: 0
    };
  }

  async selectCircuit(id) {
    if (id != -1) {
      this.circuit = await getCircuit(id);
    }
    update();
  }

  updateEndpoint(e) {
    if (e.index < 0) {
      this.circuit.endpoints.push(e);
    } else {
      this.circuit.endpoints[e.index] = e;
    }
    update();
  }

  deleteEndpoint(i) {
    this.circuit.endpoints.splice(i, 1);
    update();
  }

  saveCircuit() {
    console.log('provisionCircuit:', this.circuit);

    provisionCircuit(
      session.data.workgroup_id,
      this.circuit.description,
      this.circuit.endpoints,
      this.circuit.static_mac,
      this.circuit.provision_time,
      this.circuit.remove_time,
      this.circuit.circuit_id
    ).then(function(result) {
      if (result !== null && result.success == 1) {
        window.location.href = `index.cgi?action=modify_l2vpn&circuit_id=${result.circuit_id}`;
      }
    });
  }

  deleteCircuit() {
    if (!window.confirm('Are you sure you wish to cancel? All your changes will be lost.')) {
      return null;
    }

    window.location.href = 'index.cgi';
    return 1;
  }
}

let state = new GlobalState();

document.querySelector('.l2vpn-new-endpoint-button').addEventListener('click', function(e) {
  PopulateInterfaceForm(null);
  PopulateEntityForm(null);
  $('#add-endpoint-modal').modal('show');
});

document.querySelector('.l2vpn-cancel-button').addEventListener('click', function(e) {
  if (window.confirm('Are you sure you wish to cancel? All your changes will be lost.')) {
    window.location.href = 'index.cgi';
  }
});

document.querySelector('.l2vpn-save-button').addEventListener('click', function(e) {
  state.circuit.description = document.querySelector('#l2vpn-circuit-description').value;

  if (document.querySelector('#l2vpn-circuit-create-now').checked) {
    state.circuit.provision_time = -1;
  } else {
    state.circuit.provision_time = new Date(document.querySelector('#l2vpn-circuit-create-picker').value).getTime() / 1000;
  }

  if (document.querySelector('#l2vpn-circuit-remove-never').checked) {
    state.circuit.remove_time = -1;
  } else {
    state.circuit.remove_time = new Date(document.querySelector('#l2vpn-circuit-remove-picker').value).getTime() / 1000;
  }

  state.saveCircuit();
});

document.querySelectorAll('.l2vpn-circuit-create-radio').forEach((elem) => {
  elem.addEventListener('change', function(e) {
    if (document.querySelector('#l2vpn-circuit-create-now').checked) {
      document.querySelector('#l2vpn-circuit-create-picker').style.display = 'none';
    } else {
      document.querySelector('#l2vpn-circuit-create-picker').style.display = 'block';
    }
  });
});

document.querySelectorAll('.l2vpn-circuit-remove-radio').forEach((elem) => {
  elem.addEventListener('change', function(e) {
    if (document.querySelector('#l2vpn-circuit-remove-never').checked) {
      document.querySelector('#l2vpn-circuit-remove-picker').style.display = 'none';
    } else {
      document.querySelector('#l2vpn-circuit-remove-picker').style.display = 'block';
    }
  });
});

async function update(props) {
  let list = document.getElementById('endpoints');
  list.innerHTML = '';
  state.circuit.endpoints.map(function(e, i) {
    e.index = i;

    let elem = NewEndpoint(e);
    list.appendChild(elem);
  });
}

document.addEventListener('DOMContentLoaded', function() {
  loadUserMenu();

  let url = new URL(window.location.href);
  let id = url.searchParams.get('circuit_id');

  let editable = (session.data.isAdmin || !session.data.isReadOnly);

  state = new GlobalState();
  console.log('GlobalState:', state);

  state.selectCircuit(-1);

  let map = new NDDIMap('map');
  map.on("loaded", function(){
    this.updateMapFromSession(session);
  });
});
