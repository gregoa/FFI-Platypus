use strict;
use warnings;
use FFI::Platypus;

my $ffi = FFI::Platypus->new;
$ffi->lib('./libvar_array.so');

$ffi->attach( sum => [ 'int[]', 'int' ] => 'int' );

my @list = (1..100);

print sum(\@list, scalar @list), "\n";
