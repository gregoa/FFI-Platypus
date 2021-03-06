use strict;
use warnings;
use utf8;
# see https://github.com/Perl5-FFI/FFI-Platypus/issues/85
use if $^O ne 'MSWin32' || $] >= 5.018, 'open', ':std', ':encoding(utf8)';
use Test::More;
use Encode qw( decode );
use FFI::Platypus::Buffer qw( scalar_to_buffer buffer_to_scalar );

subtest simple => sub {
  my $orig = 'me grimlock king';
  my($ptr, $size) = scalar_to_buffer($orig);
  ok $ptr, "ptr = $ptr";
  is $size, 16, 'size = 16';
  my $scalar = buffer_to_scalar($ptr, $size);
  is $scalar, 'me grimlock king', "scalar = $scalar";
};

subtest unicode => sub {
  my $orig = 'привет';
  my($ptr, $size) = scalar_to_buffer($orig);
  ok $ptr, "ptr = $ptr";
  ok $size, "size = $size";
  my $scalar = decode('UTF-8', buffer_to_scalar($ptr, $size));
  is $scalar, 'привет', "scalar = $scalar";
};

done_testing;
