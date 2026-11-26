package PVE::QemuServer::Iucv;

# IUCV of s390x VMs, provided by QEMU as z/VM's CP provides it: network devices of the kinds
# 'iucv-net' (a point-to-point IP link, the protocol of Linux netiucv) and 'iucv-tcpip' (the
# socket interface of a VM TCP/IP machine, with a TCP/IP stack of its own that is a host on the
# bridge of the NIC), and the VM option 'iucv' for the behaviour of the IUCV instruction itself.

use strict;
use warnings;

use PVE::JSONSchema qw(parse_property_string);
use PVE::Network;

use PVE::QemuServer::Helpers;

my $USERID_PATTERN = '[A-Za-z0-9@#$]{1,8}';
my $DEFAULT_PEER = 'TCPIP';
my $IPV4_PATTERN = '\d{1,3}(?:\.\d{1,3}){3}';
my $MAX_DNS = 3;
my $HOSTNAME_PATTERN = '[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?';

my $iucv_fmt = {
    mode => {
        type => 'string',
        enum => ['none', 'unavailable', 'full'],
        default_key => 1,
        description => "What the IUCV instruction does. 'none': nothing is provided, the"
            . " instruction is an operation exception as on a machine without a hypervisor"
            . " (IUCV network devices still provide IUCV). 'unavailable': IUCV is not offered,"
            . " the instruction ends with condition code 3, as under a hypervisor without IUCV"
            . " for the guest; some operating systems need this. 'full': IUCV is provided even"
            . " without IUCV network devices.",
        default => 'none',
        optional => 1,
    },
    userid => {
        type => 'string',
        pattern => $USERID_PATTERN,
        format_description => 'userid',
        description => "The user ID of the VM for IUCV and the z/VM personality (default"
            . " 'GUEST').",
        optional => 1,
    },
};
PVE::JSONSchema::register_format('pve-qm-iucv', $iucv_fmt);

our $iucv_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-iucv',
    description => "IUCV of an s390x VM: the behaviour of the IUCV instruction and the user ID"
        . " of the VM. IUCV services are added as network devices of the kinds 'iucv-net' and"
        . " 'iucv-tcpip'.",
};

# the properties of network devices that only IUCV kinds use
our $net_fmt_iucv = {
    'iucv-peer' => {
        type => 'string',
        pattern => $USERID_PATTERN,
        format_description => 'userid',
        description => "IUCV kinds: the user ID the guest connects to (default '$DEFAULT_PEER')."
            . " Unique among the IUCV network devices of the VM.",
        optional => 1,
    },
    'iucv-ip' => {
        type => 'string',
        format => 'CIDRv4',
        format_description => 'IPv4/prefix',
        description => "IUCV kinds: the IPv4 address of the guest with its prefix length"
            . " (required). iucv-tcpip: the address the TCP/IP stack of the device has on the"
            . " bridge, not the network or broadcast address of its subnet.",
        optional => 1,
    },
    'iucv-gw' => {
        type => 'string',
        format => 'ipv4',
        format_description => 'IPv4',
        description => "IUCV kinds: the gateway for addresses outside the guest's subnet, an"
            . " address inside it (required for iucv-tcpip).",
        optional => 1,
    },
    'iucv-dns' => {
        type => 'string',
        pattern => "$IPV4_PATTERN(?:;$IPV4_PATTERN){0," . ($MAX_DNS - 1) . "}",
        format_description => 'IPv4[;IPv4...]',
        description => "iucv-tcpip: the name servers of the guest, up to $MAX_DNS (required)."
            . " The resolver configuration of the guest has to name the same servers.",
        optional => 1,
    },
    'iucv-hostname' => {
        type => 'string',
        pattern => $HOSTNAME_PATTERN,
        format_description => 'hostname',
        description => "iucv-tcpip: the host name of the guest, without the domain (GETHOSTNAME;"
            . " required).",
        optional => 1,
    },
    'iucv-domain' => {
        type => 'string',
        format => 'dns-name',
        format_description => 'domain',
        description => "iucv-tcpip: the DNS domain of the guest (required).",
        optional => 1,
    },
};

# the IUCV properties of each kind
my $kind_keys = {
    'iucv-net' => [qw(iucv-peer iucv-ip iucv-gw)],
    'iucv-tcpip' => [qw(iucv-peer iucv-ip iucv-gw iucv-dns iucv-hostname iucv-domain)],
};

# the properties an iucv-tcpip device needs, in the order they are checked
my $tcpip_required = [qw(iucv-ip iucv-gw iucv-dns iucv-hostname iucv-domain)];

# the general properties of network devices that a kind cannot use
my $kind_unsupported = {
    'iucv-net' => [qw(devno host-tunnel loadparm queues)],
    'iucv-tcpip' => [qw(devno host-tunnel loadparm queues trunks)],
};

sub is_iucv_model {
    my ($model) = @_;
    return defined($model) && ($model eq 'iucv-net' || $model eq 'iucv-tcpip');
}

sub parse_iucv {
    my ($value) = @_;
    return {} if !defined($value);
    return parse_property_string($iucv_fmt, $value);
}

my sub parse_net_quiet {
    my ($value) = @_;

    require PVE::QemuServer::Network; # it uses this module for its format

    local $SIG{__WARN__} = sub { };
    return PVE::QemuServer::Network::parse_net($value, 1);
}

# the IUCV network devices of a configuration, [ [ netid, parsed ], ... ]
sub iucv_nets {
    my ($conf) = @_;

    my $res = [];
    for my $key (sort keys %$conf) {
        next if $key !~ m/^net\d+$/ || !defined($conf->{$key});
        my $net = parse_net_quiet($conf->{$key});
        push @$res, [$key, $net] if $net && is_iucv_model($net->{model});
    }
    return $res;
}

# the subnet of an address with prefix length (a Net::IP object)
my sub ipv4_subnet {
    my ($cidr) = @_;
    return PVE::Network::IP_from_cidr($cidr, 4);
}

# The problems of the IUCV setup of a configuration (network devices, the option 'iucv') as
# { key => message }; empty if there are none.
sub check_config {
    my ($conf, $arch) = @_;

    my $errors = {};
    my $peers = {};
    my ($tcpip_key, @iucv_nets);

    my @keys = grep { m/^net\d+$/ } keys %$conf;
    for my $key (sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } @keys) {
        next if !defined($conf->{$key});
        my $net = parse_net_quiet($conf->{$key}) or next; # the schema reports those
        my $model = $net->{model};
        my $error = sub { $errors->{$key} //= shift; };

        if (!is_iucv_model($model)) {
            my ($opt) = grep { defined($net->{$_}) } sort keys %$net_fmt_iucv;
            $error->("'$opt' is only for IUCV network devices (iucv-net, iucv-tcpip)")
                if defined($opt);
            next;
        }
        if ($arch ne 's390x') {
            $error->("IUCV network devices are only supported on s390x");
            next;
        }
        push @iucv_nets, $key;

        my %own = map { $_ => 1 } $kind_keys->{$model}->@*;
        my ($foreign) = grep { defined($net->{$_}) && !$own{$_} } sort keys %$net_fmt_iucv;
        my ($unsupported) = grep { defined($net->{$_}) } $kind_unsupported->{$model}->@*;
        if (defined($foreign)) {
            $error->("'$foreign' is only for iucv-tcpip, not for $model");
            next;
        } elsif (defined($unsupported)) {
            $error->("'$unsupported' is not supported by $model");
            next;
        }

        if ($model eq 'iucv-tcpip') {
            # one TCP/IP stack per QEMU process
            if (defined($tcpip_key)) {
                $error->("only one IUCV TCP/IP network device per VM, $tcpip_key is one");
                next;
            }
            $tcpip_key = $key;
            if (!$net->{bridge}) {
                $error->("iucv-tcpip needs a bridge");
                next;
            }
            my ($missing) = grep { !defined($net->{$_}) } @$tcpip_required;
            if (defined($missing)) {
                $error->("iucv-tcpip needs '$missing'");
                next;
            }
        }

        my $ip = $net->{'iucv-ip'};
        if (!defined($ip)) {
            $error->("an IUCV network device needs an address (iucv-ip)");
            next;
        }
        my ($addr, $prefix) = split(m!/!, $ip);
        my $subnet = ipv4_subnet($ip);

        my $peer = uc($net->{'iucv-peer'} // $DEFAULT_PEER);
        if (my $other_key = $peers->{$peer}) {
            $error->("iucv-peer: the user ID $peer is already used by $other_key");
        }
        $peers->{$peer} = $key;

        if ($model eq 'iucv-tcpip' && $subnet && $prefix < 31) {
            if ($addr eq $subnet->ip()) {
                $error->("iucv-ip: $addr is the network address of its subnet "
                    . $subnet->prefix());
            } elsif ($addr eq $subnet->last_ip()) {
                $error->("iucv-ip: $addr is the broadcast address of its subnet "
                    . $subnet->prefix());
            }
        }

        if (my $gw = $net->{'iucv-gw'}) {
            if ($gw eq $addr) {
                $error->("iucv-gw: the gateway is the address of the guest");
            } elsif (!PVE::Network::is_ip_in_cidr($gw, $ip, 4)) {
                $error->("iucv-gw: the gateway $gw is not in the guest's subnet "
                    . ($subnet ? $subnet->prefix() : $ip));
            }
        }

        for my $dns (split(/;/, $net->{'iucv-dns'} // '')) {
            if (!PVE::JSONSchema::pve_verify_ipv4($dns, 1)) {
                $error->("iucv-dns: '$dns' is not an IPv4 address");
                last;
            }
        }

        if (defined(my $mtu = $net->{mtu})) {
            if ($mtu == 1) {
                $error->("mtu: '1' (the MTU of the bridge) needs a bridge") if !$net->{bridge};
            } elsif ($mtu < 576) {
                $error->("mtu: '$mtu' is smaller than the IP minimum MTU '576'");
            }
        }
    }

    if (defined($conf->{iucv})) {
        my $iucv = eval { parse_iucv($conf->{iucv}) };
        if (!$iucv) {
            # the schema reports those
        } elsif ($arch ne 's390x') {
            $errors->{iucv} = "only supported on s390x";
        } elsif (($iucv->{mode} // 'none') eq 'unavailable' && @iucv_nets) {
            $errors->{iucv} = "mode unavailable cannot be combined with IUCV network devices ("
                . join(', ', @iucv_nets) . ")";
        }
    }

    return $errors;
}

sub assert_config {
    my ($conf, $arch) = @_;

    my $errors = check_config($conf, $arch);
    my ($key) = sort keys %$errors;
    die "$key: $errors->{$key}\n" if defined($key);
    return;
}

# -device arguments for the IUCV core, and the machine properties
sub get_command_args {
    my ($conf, $arch, $kvm_binary) = @_;

    # also refuses IUCV properties of other network devices
    assert_config($conf, $arch);

    my $nets = iucv_nets($conf);
    my ($devices, $machine) = ([], []);
    my $iucv = parse_iucv($conf->{iucv});
    my $mode = $iucv->{mode} // 'none';
    return ($devices, $machine) if $mode eq 'none' && !$iucv->{userid} && !@$nets;

    my $types = PVE::QemuServer::Helpers::kvm_device_types($kvm_binary);
    die "iucv: the installed QEMU has no IUCV (s390-iucv)\n" if !$types->{'s390-iucv'};

    if ($mode eq 'unavailable') {
        push @$devices, '-device', 's390-iucv,id=iucv,available=off';
    } elsif ($mode eq 'full') {
        push @$devices, '-device', 's390-iucv,id=iucv';
    }
    push @$machine, 'zvm-userid=' . uc($iucv->{userid}) if $iucv->{userid};
    # Linux uses IUCV only when it finds itself under z/VM
    push @$machine, 'zvm-personality=on' if grep { $_->[1]->{model} eq 'iucv-net' } @$nets;

    return ($devices, $machine);
}

# the MTU property of an IUCV network device, '1' is the MTU of the bridge as for VirtIO
my sub mtu_property {
    my ($net, $netid) = @_;

    my $mtu = $net->{mtu};
    return '' if !defined($mtu);
    if ($net->{bridge}) {
        my $bridge_mtu = PVE::Network::read_bridge_mtu($net->{bridge});
        if ($mtu == 1) {
            $mtu = $bridge_mtu;
        } elsif ($mtu > $bridge_mtu) {
            die "$netid: MTU '$mtu' is bigger than the bridge MTU '$bridge_mtu'\n";
        }
    }
    return $mtu != 1 ? ",mtu=$mtu" : '';
}

# the -device value of an IUCV network device on the netdev $netid; the configuration was
# checked with assert_config()
sub print_iucv_netdevice {
    my ($net, $netid) = @_;

    die "$netid: an IUCV network device needs an address (iucv-ip)\n" if !$net->{'iucv-ip'};
    my $peer = uc($net->{'iucv-peer'} // $DEFAULT_PEER);

    if ($net->{model} eq 'iucv-net') {
        my $dev = "iucv-net,id=$netid,name=$peer,ip=$net->{'iucv-ip'}";
        $dev .= ",netdev=$netid,mac=$net->{macaddr}";
        $dev .= ",gateway=$net->{'iucv-gw'}" if $net->{'iucv-gw'};
        $dev .= mtu_property($net, $netid);
        return $dev;
    }

    die "$netid: iucv-tcpip needs a bridge\n" if !$net->{bridge};
    for my $key (@$tcpip_required) {
        die "$netid: iucv-tcpip needs '$key'\n" if !defined($net->{$key});
    }
    my $dev = "iucv-tcpip,id=$netid,name=$peer,netdev=$netid,mac=$net->{macaddr}";
    $dev .= ",ip=$net->{'iucv-ip'},gateway=$net->{'iucv-gw'},dns=$net->{'iucv-dns'}";
    $dev .= ",hostname=$net->{'iucv-hostname'},domain=$net->{'iucv-domain'}";
    $dev .= mtu_property($net, $netid);
    return $dev;
}

# IUCV paths end with the QEMU process: no live migration, no snapshot with RAM
sub has_iucv {
    my ($conf) = @_;

    my $iucv = eval { parse_iucv($conf->{iucv}) } // {};
    return ($iucv->{mode} // 'none') eq 'full' || scalar(@{ iucv_nets($conf) });
}

1;
