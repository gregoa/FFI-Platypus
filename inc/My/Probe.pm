package My::Probe;

use strict;
use warnings;
use Config;
use File::Spec;
use FindBin;
use My::ShareConfig;
use My::ConfigH;
use lib 'lib';
use FFI::Probe;
use FFI::Probe::Runner;
use File::Glob qw( bsd_glob );
use File::Basename qw( basename );

my @probe_types = split /\n/, <<EOF;
char
signed char
unsigned char
short
signed short
unsigned short
int
signed int
unsigned int
long
signed long
unsigned long
uint8_t
int8_t
uint16_t
int16_t
uint32_t
int32_t
uint64_t
int64_t
size_t
ssize_t
float
double
long double
float complex
double complex
long double complex
bool
_Bool
pointer
EOF

my @extra_probe_types = split /\n/, <<EOF;
long long
signed long long
unsigned long long
dev_t
ino_t
mode_t
nlink_t
uid_t
gid_t
off_t
blksize_t
blkcnt_t
time_t
ptrdiff_t
wchar_t
wint_t
EOF

push @probe_types, @extra_probe_types unless $ENV{FFI_PLATYPUS_NO_EXTRA_TYPES};

my $config_h = File::Spec->rel2abs( File::Spec->catfile( 'include', 'ffi_platypus_config.h' ) );

sub configure
{
  my($self, $share_config) = @_;

  my $probe = FFI::Probe->new(
    runner => FFI::Probe::Runner->new(
      exe => "blib/lib/auto/share/dist/FFI-Platypus/probe/bin/dlrun$Config{exe_ext}",
    ),
    log => "config.log",
    data_filename => "blib/lib/auto/share/dist/FFI-Platypus/probe/probe.pl",
    alien => [$share_config->get('alien')->{class}],
    cflags => ['-Iinclude'],
  );

  return if -r $config_h && ref($share_config->get( 'type_map' )) eq 'HASH';

  my $ch = My::ConfigH->new;

  $ch->define_var( do {
    my $os = uc $^O;
    $os =~ s/-/_/;
    $os =~ s/[^A-Z0-9_]//g;
    "PERL_OS_$os";
  } => 1 );

  $ch->define_var( PERL_OS_WINDOWS => 1 ) if $^O =~ /^(MSWin32|cygwin|msys)$/;

  foreach my $header (qw( stdlib stdint sys/types sys/stat unistd alloca dlfcn limits stddef wchar signal inttypes windows sys/cygwin string psapi stdio stdbool complex ))
  {
    if($probe->check_header("$header.h"))
    {
      my $var = uc $header;
      $var =~ s{/}{_}g;
      $var = "HAVE_${var}_H";
      $ch->define_var( $var => 1 );
    }
  }

  if(!$share_config->get('config_debug_fake32') && $Config{ivsize} >= 8)
  {
    $ch->define_var( HAVE_IV_IS_64 => 1 );
  }
  else
  {
    $ch->define_var( HAVE_IV_IS_64 => 0 );
  }

  my %type_map;
  my %align;

  foreach my $type (@probe_types)
  {
    my $ok;

    if($type =~ /^(float|double|long double)/)
    {
      if(my $basic = $probe->check_type_float($type))
      {
        $type_map{$type} = $basic;
        $align{$type} = $probe->data->{type}->{$type}->{align};
      }
    }
    elsif($type eq 'pointer')
    {
      $probe->check_type_pointer;
      $align{pointer} = $probe->data->{type}->{pointer}->{align};
    }
    else
    {
      if(my $basic = $probe->check_type_int($type))
      {
        $type_map{$type} = $basic;
        $align{$basic} ||= $probe->data->{type}->{$type}->{align};
      }
    }
  }

  $ch->define_var( SIZEOF_VOIDP => $probe->data->{type}->{pointer}->{size} );
  if(my $size = $probe->data->{type}->{'float complex'}->{size})
  { $ch->define_var( SIZEOF_FLOAT_COMPLEX => $size ) }
  if(my $size = $probe->data->{type}->{'double complex'}->{size})
  { $ch->define_var( SIZEOF_DOUBLE_COMPLEX => $size ) }
  if(my $size = $probe->data->{type}->{'long double complex'}->{size})
  { $ch->define_var( SIZEOF_LONG_DOUBLE_COMPLEX => $size ) }

  # short aliases
  $type_map{uchar}  = $type_map{'unsigned char'};
  $type_map{ushort} = $type_map{'unsigned short'};
  $type_map{uint}   = $type_map{'unsigned int'};
  $type_map{ulong}  = $type_map{'unsigned long'};

  # on Linux and OS X at least the test for bool fails
  # but _Bool works (even though code using bool seems
  # to work for both).  May be because bool is a macro
  # for _Bool or something.
  $type_map{bool} ||= delete $type_map{_Bool};
  delete $type_map{_Bool};

  $ch->write_config_h;

  my %probe;
  if(defined $ENV{FFI_PLATYPUS_PROBE_OVERRIDE})
  {
    foreach my $kv (split /:/, $ENV{FFI_PLATYPUS_PROBE_OVERRIDE})
    {
      my($k,$v) = split /=/, $kv, 2;
      $probe{$k} = $v;
    }
  }

  foreach my $cfile (bsd_glob 'inc/probe/*.c')
  {
    my $name = basename $cfile;
    $name =~ s/\.c$//;
    unless(defined $probe{$name})
    {
      my $code = do {
        my $fh;
        open $fh, '<', $cfile;
        local $/;
        <$fh>;
      };
      my $value = $probe->check($name, $code);
      $probe{$name} = $value if defined $value;
    }
    if($probe{$name})
    {
      $ch->define_var( "FFI_PL_PROBE_" . uc($name) => 1 );
    }
  }

  my %abi;

  if(my $cpp_output = $probe->check_cpp("#include <ffi.h>\n"))
  {
    if($cpp_output =~ m/typedef\s+enum\s+ffi_abi\s+{(.*?)}/s)
    {
      my $enum = $1;
      while($enum =~ s/FFI_([A-Z_0-9]+)//)
      {
        my $abi = $1;
        next if $abi =~ /^(FIRST|LAST)_ABI$/;
        $probe->check_eval(
          decl => [
            "#include \"ffi_platypus.h\"",
          ],
          stmt => [
            "ffi_cif cif;",
            "ffi_type *args[1];",
            "ffi_abi abi;",
            "if(ffi_prep_cif(&cif, FFI_$abi, 0, &ffi_type_void, args) != FFI_OK) { return 2; }",
          ],
          eval => {
            "abi.@{[ lc $abi ]}" => [ '%d' => "FFI_$abi" ],
          },
        );
      }
      if(defined $probe->data->{abi})
      {
        %abi = %{ $probe->data->{abi} || {} };
      }
      else
      {
        print "Unable to verify any ffi_abis.\n";
        print "only default ABI will be available\n";
      }
    }
    else
    {
      print "Unable to find ffi_abi enum.\n";
      print "only default ABI will be available\n";
    }
  }
  else
  {
    print "C pre-processor failed...\n";
    print "only default ABI will be available\n";
  }

  $ch->write_config_h;
  $share_config->set( type_map => \%type_map );
  $share_config->set( align    => \%align    );
  $share_config->set( probe    => \%probe    );
  $share_config->set( abi      => \%abi      );
}

1;
