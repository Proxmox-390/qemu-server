package PVE::QemuServer::DisabledWait;

# A disabled wait of an s390x guest as the end of its shutdown.
#
# The mainframe operating systems do not power their machine off: they end a shutdown by
# loading a disabled wait PSW on the last CPU, with a wait state code in the rightmost three
# hexadecimal digits of its instruction address (X'CCC' after a quiesce, for example). When no
# CPU is left running, QEMU reports that as the 'guest-panicked' run state with the crash reason
# 'disabled-wait' and the QEMU process keeps running. A wait code of X'FFF' is the exception:
# QEMU itself treats it as a shutdown of the guest.
#
# The option 's390-shutdown-wait' decides which disabled waits of a VM whose OS type is not
# Linux mean "powered off":
#
# - After a shutdown requested through the host (qm shutdown, qm reboot, the API, HA, a stop mode
#   backup), the wait codes in 'codes' (default: any code) end the shutdown: the QEMU process is
#   quit and the shutdown task finishes successfully. Without a request, a disabled wait stays
#   the neutral 'disabled-wait' status of the VM.
# - With 'guest' set, the guest shutting itself down counts as well: qmeventd reports the guest
#   panic and 'qm disabled-wait' stops the VM when the wait code is in 'codes'.
#
# A Linux kernel panic also ends in a disabled wait, so none of this applies to Linux guests.

use strict;
use warnings;

use PVE::JSONSchema;

use PVE::QemuServer::Helpers;

my $shutdown_wait_fmt = {
    codes => {
        type => 'string',
        pattern => qr/any|[0-9a-fA-F]{1,3}(?:;[0-9a-fA-F]{1,3})*/,
        format_description => 'any|code[;code...]',
        description => "The wait state codes (the rightmost three hexadecimal digits of the"
            . " instruction address of the disabled wait PSW) that mean the guest shut down,"
            . " or 'any' for every disabled wait.",
        default => 'any',
        optional => 1,
    },
    guest => {
        type => 'boolean',
        description => "Also stop the VM when the guest shuts itself down (no shutdown requested"
            . " through the host) and ends in a disabled wait with one of the 'codes'. Then the VM"
            . " is stopped, as after a shutdown, and is not started again: a VM managed by HA is"
            . " started again by HA, as after a shutdown from inside any guest.",
        default => 0,
        optional => 1,
    },
};

PVE::JSONSchema::register_format('pve-qm-s390-shutdown-wait', $shutdown_wait_fmt);

our $shutdown_wait_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-s390-shutdown-wait',
    description => "s390x, OS types other than Linux: which disabled waits of the guest end its"
        . " shutdown. Mainframe operating systems end a shutdown in a disabled wait instead of"
        . " powering off. After a shutdown requested through the host (shutdown, reboot, HA), a"
        . " disabled wait with one of the wait state codes 'codes' stops the VM and the shutdown"
        . " succeeds; with 'guest', also a shutdown from inside the guest. Applies at once.",
};

sub parse_shutdown_wait {
    my ($value) = @_;

    my $res = defined($value) ? PVE::JSONSchema::parse_property_string($shutdown_wait_fmt, $value) : {};
    my $codes = $res->{codes} // 'any';
    return {
        codes => $codes eq 'any' ? undef : { map { (wait_code($_) => 1) } split(/;/, $codes) },
        guest => $res->{guest} ? 1 : 0,
    };
}

# The wait state code of a disabled wait PSW with the instruction address $addr (a hexadecimal
# string): its rightmost three hexadecimal digits, upper case.
sub wait_code {
    my ($addr) = @_;
    return sprintf('%03X', hex(length($addr) > 3 ? substr($addr, -3) : $addr));
}

# Whether the s390-shutdown-wait handling applies to the VM with the configuration $conf at all.
sub applies {
    my ($conf) = @_;
    return PVE::QemuServer::Helpers::get_vm_arch($conf) eq 's390x'
        && !PVE::QemuServer::Helpers::is_linux_ostype($conf->{ostype});
}

# Whether a disabled wait with the PSW instruction address $addr means the guest of the VM with
# the configuration $conf shut down. $requested: a shutdown was requested through the host.
sub is_shutdown_wait {
    my ($conf, $addr, $requested) = @_;

    return 0 if !defined($addr) || !applies($conf);
    my $opts = parse_shutdown_wait($conf->{'s390-shutdown-wait'});
    return 0 if !$requested && !$opts->{guest};
    return 1 if !$opts->{codes};
    return $opts->{codes}->{ wait_code($addr) } ? 1 : 0;
}

1;
