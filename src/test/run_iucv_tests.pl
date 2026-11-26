#!/usr/bin/perl

# The IUCV of s390x VMs: the checks of a configuration, also done by the API when it is set.

use strict;
use warnings;

use lib qw(..);

use Test::More;

use PVE::QemuServer::Iucv;
use PVE::QemuServer::Network;

my $check = sub {
    my ($conf, $arch) = @_;
    # the checks skip devices the schema refuses: the test configurations must parse
    for my $key (grep { m/^net\d+$/ } sort keys %$conf) {
        die "test configuration $key does not parse: $conf->{$key}\n"
            if !PVE::QemuServer::Network::parse_net($conf->{$key}, 1);
    }
    return PVE::QemuServer::Iucv::check_config($conf, $arch // 's390x');
};

my $tcpip_base = 'iucv-tcpip=BC:24:11:00:00:02,bridge=vmbr0,iucv-gw=10.0.2.1,'
    . 'iucv-hostname=guest,iucv-domain=example.com';
my $tcpip = "$tcpip_base,iucv-dns=10.0.2.3";

subtest 'configuration checks' => sub {
    is_deeply($check->({ net0 => 'virtio=BC:24:11:00:00:01,bridge=vmbr0' }), {}, 'no IUCV');
    is_deeply(
        $check->({
            iucv => 'full,userid=linux1',
            net0 => 'iucv-net=BC:24:11:00:00:01,bridge=vmbr0,iucv-ip=10.0.3.2/24,iucv-gw=10.0.3.1',
            net1 => "$tcpip,iucv-peer=tcpip2,iucv-ip=10.0.2.15/24,tag=10,firewall=1,rate=10,"
                . 'link_down=1,mtu=1',
        }),
        {},
        'valid devices of both kinds',
    );
    is_deeply(
        $check->({
            net0 => 'iucv-net=BC:24:11:00:00:01,bridge=vmbr0,iucv-ip=10.0.3.2/24',
            net1 => 'iucv-net=BC:24:11:00:00:03,bridge=vmbr0,iucv-ip=10.0.4.2/24,iucv-peer=T2',
        }),
        {},
        'several point-to-point links',
    );
    is_deeply(
        $check->({ iucv => 'unavailable', net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0' }),
        {},
        'unavailable without IUCV network devices',
    );
    is_deeply(
        $check->({
            iucv => 'unavailable',
            net0 => "$tcpip,iucv-ip=10.0.2.15/24",
            net1 => 'iucv-net=BC:24:11:00:00:03,bridge=vmbr0,iucv-ip=10.0.3.2/24,iucv-peer=OTHER',
        }),
        { iucv => 'mode unavailable cannot be combined with IUCV network devices (net0, net1)' },
        'unavailable with IUCV network devices',
    );
    is_deeply(
        $check->({ iucv => 'none', net0 => "$tcpip,iucv-ip=10.0.2.15/24" }, 'x86_64'),
        {
            iucv => 'only supported on s390x',
            net0 => 'IUCV network devices are only supported on s390x',
        },
        'other architectures',
    );
    is_deeply(
        $check->({
            net2 => "$tcpip,iucv-ip=10.0.2.15/24",
            net10 => "$tcpip,iucv-ip=10.0.2.16/24,iucv-peer=T2",
        }),
        { net10 => 'only one IUCV TCP/IP network device per VM, net2 is one' },
        'devices in numeric order, one TCP/IP service',
    );
    is_deeply(
        $check->({ net0 => 'iucv-net,iucv-ip=10.0.3.2/32,iucv-gw=10.0.3.1' }),
        { net0 => "iucv-gw: the gateway 10.0.3.1 is not in the guest's subnet 10.0.3.2/32" },
        'a /32 address has no gateway',
    );
    is_deeply(
        $check->({ net0 => 'iucv-tcpip,iucv-ip=10.0.2.15/24' }),
        { net0 => 'iucv-tcpip needs a bridge' },
        'the TCP/IP service needs a bridge',
    );
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.2.15/24" }),
        {},
        'all required properties',
    );
    my $required = 'iucv-tcpip,bridge=vmbr0,iucv-ip=10.0.2.15/24,iucv-gw=10.0.2.1,'
        . 'iucv-dns=10.0.2.3,iucv-hostname=guest,iucv-domain=example.com';
    for my $key (qw(iucv-ip iucv-gw iucv-dns iucv-hostname iucv-domain)) {
        my $value = join(',', grep { !m/^\Q$key\E=/ } split(/,/, $required));
        is_deeply(
            $check->({ net0 => $value }),
            { net0 => "iucv-tcpip needs '$key'" },
            "the TCP/IP service needs $key",
        );
    }
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.2.0/24" }),
        { net0 => 'iucv-ip: 10.0.2.0 is the network address of its subnet 10.0.2.0/24' },
        'not the network address',
    );
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.2.255/24" }),
        { net0 => 'iucv-ip: 10.0.2.255 is the broadcast address of its subnet 10.0.2.0/24' },
        'not the broadcast address',
    );
    is_deeply(
        $check->({
            net0 => 'iucv-tcpip,bridge=vmbr0,iucv-ip=10.0.2.0/31,iucv-gw=10.0.2.1,'
                . 'iucv-dns=10.0.2.3,iucv-hostname=guest,iucv-domain=example.com',
        }),
        {},
        'both addresses of a /31',
    );
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.2.1/24" }),
        { net0 => 'iucv-gw: the gateway is the address of the guest' },
        'the gateway is not the guest',
    );
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.3.15/24" }),
        { net0 => "iucv-gw: the gateway 10.0.2.1 is not in the guest's subnet 10.0.3.0/24" },
        'the gateway is in the subnet',
    );
    is_deeply(
        $check->({ net0 => "$tcpip_base,iucv-ip=10.0.2.15/24,iucv-dns=10.0.2.3;192.0.2.53" }),
        {},
        'several name servers',
    );
    is_deeply(
        $check->({ net0 => "$tcpip_base,iucv-ip=10.0.2.15/24,iucv-dns=10.0.2.3;300.0.2.53" }),
        { net0 => "iucv-dns: '300.0.2.53' is not an IPv4 address" },
        'name servers are IPv4 addresses',
    );
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.2.15/24,mtu=500" }),
        { net0 => "mtu: '500' is smaller than the IP minimum MTU '576'" },
        'the minimum MTU of the TCP/IP service',
    );
    is_deeply(
        $check->({ net0 => "$tcpip,iucv-ip=10.0.2.15/24,queues=2" }),
        { net0 => "'queues' is not supported by iucv-tcpip" },
        'no multiqueue',
    );
    is_deeply(
        $check->({ net0 => 'iucv-net,bridge=vmbr0,iucv-ip=10.0.3.2/24,iucv-hostname=guest' }),
        { net0 => "'iucv-hostname' is only for iucv-tcpip, not for iucv-net" },
        'properties of the TCP/IP service on a point-to-point link',
    );
    is_deeply(
        $check->({ net0 => 'virtio,bridge=vmbr0,iucv-domain=example.com' }),
        { net0 => "'iucv-domain' is only for IUCV network devices (iucv-net, iucv-tcpip)" },
        'IUCV properties on other network devices',
    );
};

done_testing();
