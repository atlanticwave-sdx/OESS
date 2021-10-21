FROM centos:7
COPY globalnoc-public-el7.repo /etc/yum.repos.d/globalnoc-public-el7.repo
COPY perl-lib/OESS/entrypoint.sh /
RUN yum makecache
RUN yum -y install epel-release
RUN yum -y install git
RUN yum -y install perl mariadb-server
RUN yum -y install perl-Carp-Always perl-Test-Deep perl-Test-Exception perl-Test-Pod perl-Test-Pod-Coverage perl-Devel-Cover perl-AnyEvent-HTTP
RUN yum -y install perl-OESS oess-core oess-frontend
#RUN git clone https://github.com/GlobalNOC/OESS.git
RUN git clone https://github.com/atlanticwave-sdx/OESS.git
RUN ln -s OESS/perl-lib /perl-lib
RUN chmod 777 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
