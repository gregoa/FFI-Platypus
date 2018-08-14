use strict;
use warnings;
use Test::More;
use FFI::Platypus;

my $closure = FFI::Platypus::Closure->new(sub { $_[0] + 1});
isa_ok $closure, 'FFI::Platypus::Closure';
is $closure->(1), 2, 'closure.(1) = 2';

done_testing;
