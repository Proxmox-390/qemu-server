#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::More;

use PVE::QemuServer::Tape;

# value of a tape drive => [parsed sizes in bytes, canonical value printed from the parsed one]
my $tests = [
    [
        'local:iso/T.aws,capacity=64M',
        { capacity => 67108864 },
        'local:iso/T.aws,capacity=64M',
    ],
    [
        'local:iso/T.aws,capacity=67108864,eot-margin=1048576',
        { capacity => 67108864, 'eot-margin' => 1048576 },
        'local:iso/T.aws,capacity=64M,eot-margin=1M',
    ],
    [
        'local:iso/T.aws,capacity=1.5G,eot-margin=16MiB',
        { capacity => 1610612736, 'eot-margin' => 16777216 },
        'local:iso/T.aws,capacity=1536M,eot-margin=16M',
    ],
    [
        'local:iso/T.aws,rw=1,capacity=800M,eot-margin=64K,max-blocks=100000,eot-margin-blocks=100',
        { capacity => 838860800, 'eot-margin' => 65536 },
        'local:iso/T.aws,capacity=800M,eot-margin=64K,eot-margin-blocks=100,max-blocks=100000,rw=1',
    ],
    [
        'none,capacity=1000,eot-margin=2T',
        { capacity => 1000, 'eot-margin' => 2199023255552 },
        'none,capacity=1000,eot-margin=2T',
    ],
];

for my $test ($tests->@*) {
    my ($value, $sizes, $canonical) = $test->@*;
    my $tape = PVE::QemuServer::Tape::parse_tape($value);
    for my $opt (sort keys $sizes->%*) {
        is($tape->{$opt}, $sizes->{$opt}, "$value - $opt in bytes");
    }
    my $printed = PVE::QemuServer::Tape::print_tape($tape);
    is($printed, $canonical, "$value - canonical value");
    is(
        PVE::QemuServer::Tape::print_tape(PVE::QemuServer::Tape::parse_tape($printed)),
        $printed,
        "$value - canonical value is stable",
    );
}

for my $value ('local:iso/T.aws,capacity=64X', 'local:iso/T.aws,eot-margin=-1') {
    eval { PVE::QemuServer::Tape::parse_tape($value) };
    like($@, qr/eot-margin|capacity/, "$value - refused");
}

done_testing();
