package mymm;

use strict;
use warnings;
use Config;
use File::Glob qw( bsd_glob );
use ExtUtils::MakeMaker ();
use IPC::Cmd qw( can_run );
use lib 'inc';
use My::ShareConfig;

sub _pkg_config_exe
{
  foreach my $cmd ($ENV{PKG_CONFIG}, qw( pkgconf pkg-config ))
  {
    next unless defined $cmd;
    return $cmd if can_run($cmd);
  }
  return;
}

sub _pkg_config
{
  my(@args) = @_;
  my $cmd = _pkg_config_exe;
  if(defined $cmd)
  {
    my @cmd = ($cmd, @args);
    print "+@cmd\n";
    system @cmd;
    return $? == 0;
  }
  else
  {
    print "no pkg-config.\n";
    return;
  }
}

sub myWriteMakefile
{
  my %args = @_;
  my $share_config = My::ShareConfig->new;
  my %diag;
  my %alien;

  ExtUtils::MakeMaker->VERSION('7.12');

  if(eval { require Alien::FFI; Alien::FFI->VERSION('0.20'); 1 })
  {
    print "using already installed Alien::FFI (version @{[ Alien::FFI->VERSION ]})\n";
    $share_config->set(alien => { class => 'Alien::FFI', mode => 'already-installed' });
    require Alien::Base::Wrapper;
    Alien::Base::Wrapper->import( 'Alien::FFI', 'Alien::psapi', '!export' );
    %alien = Alien::Base::Wrapper->mm_args;
  }
  else
  {
    if(_pkg_config('--exists', 'libffi'))
    {
      print "using system libffi via @{[ _pkg_config_exe ]}\n";
      $share_config->set(alien => { class => 'Alien::FFI::pkgconfig', mode => 'system' });
      require Alien::Base::Wrapper;
      Alien::Base::Wrapper->import( 'Alien::FFI::pkgconfig', 'Alien::psapi', '!export' );
      %alien = Alien::Base::Wrapper->mm_args;
    }
    else
    {
      print "requiring Alien::FFI in fallback mode.\n";
    $share_config->set(alien => { class => 'Alien::FFI', mode => 'fallback' });
      %alien = (
        CC => '$(FULLPERL) -Iinc -MAlien::Base::Wrapper=Alien::FFI,Alien::psapi -e cc --',
        LD => '$(FULLPERL) -Iinc -MAlien::Base::Wrapper=Alien::FFI,Alien::psapi -e ld --',
      );
      $args{BUILD_REQUIRES}->{'Alien::FFI'} = '0.20';
    }
  }
  $alien{INC} = defined $alien{INC} ? "-Iinclude $alien{INC}" : "-Iinclude";

  %args = (%args, %alien);

  if($ENV{FFI_PLATYPUS_DEBUG_FAKE32} || $Config{uvsize} < 8)
  {
    $args{BUILD_REQUIRES}->{'Math::Int64'} = '0.34';
  }

  if($ENV{FFI_PLATYPUS_DEBUG_FAKE32} && $Config{uvsize} == 8)
  {
    print "DEBUG_FAKE32:\n";
    print "  + making Math::Int64 a prereq\n";
    print "  + Using Math::Int64's C API to manipulate 64 bit values\n";
    $share_config->set(config_debug_fake32 => 1);
    $diag{config}->{config_debug_fake32} = 1;
  }
  if($ENV{FFI_PLATYPUS_NO_ALLOCA})
  {
    print "NO_ALLOCA:\n";
    print "  + alloca() will not be used, even if your platform supports it.\n";
    $share_config->set(config_no_alloca => 1);
    $diag{config}->{config_no_alloca} = 1;
  }

  delete $args{PM};
  $args{XSMULTI} = 1;
  $args{XSBUILD} = {
    xs => {
      'lib/FFI/Platypus' => {
        OBJECT => 'lib/FFI/Platypus$(OBJ_EXT) ' . join(' ', map { s/\.c$/\$(OBJ_EXT)/; $_ } bsd_glob "xs/*.c"),
        %alien,
      },
    },
  };

  $args{PREREQ_PM}->{'Math::Int64'} = '0.34'
    if $ENV{FFI_PLATYPUS_DEBUG_FAKE32} || $Config{uvsize} < 8;

  # dlext as understood by MB and MM
  my @dlext = ($Config{dlext});

  # extra dlext as understood by the OS
  push @dlext, 'dll'             if $^O =~ /^(cygwin|MSWin32|msys)$/;
  push @dlext, 'xs.dll'          if $^O =~ /^(MSWin32)$/;
  push @dlext, 'so'              if $^O =~ /^(cygwin|darwin)$/;
  push @dlext, 'bundle', 'dylib' if $^O =~ /^(darwin)$/;

  # uniq'ify it
  @dlext = do { my %seen; grep { !$seen{$_}++ } @dlext };

  #print "dlext[]=$_\n" for @dlext;

  $share_config->set(diag => \%diag);
  $share_config->set(config_dlext => \@dlext);

  ExtUtils::MakeMaker::WriteMakefile(%args);
}

package MY;

sub dynamic_lib
{
  my($self, @therest) = @_;
  my $dynamic_lib = $self->SUPER::dynamic_lib(@therest);

  my %h = map { m!include/(.*?)$! && $1 => [$_] } File::Glob::bsd_glob('include/*.h');
  push @{ $h{"ffi_platypus.h"} }, map { "include/ffi_platypus_$_.h" } qw( config );

  my %targets = (
    'include/ffi_platypus_config.h' => ['_mm/config'],
    'lib/FFI/Platypus.c' => [File::Glob::bsd_glob('xs/*.xs'), 'lib/FFI/Platypus.xs', 'lib/FFI/typemap'],
  );

  foreach my $cfile (File::Glob::bsd_glob('xs/*.c'), 'lib/FFI/Platypus.c')
  {
    my $ofile = $cfile;
    $ofile =~ s/\.c$/\$(OBJ_EXT)/;

    my @deps = ($cfile, '_mm/config');

    if(-d ".git")
    {
      # for a development build, lets go ahead and compute the .h
      # dependencies to make it easier to do a partial rebuild.
      my $source_file = $cfile;
      $source_file = 'lib/FFI/Platypus.xs' if $source_file =~ /^lib\/FFI/;
      my $fh;
      open $fh, '<', $source_file;
      while(<$fh>)
      {
        if(/^#include [<"](.*?)[>"]/ && $h{$1})
        {
          push @deps, @{$h{$1}};
        }
      }
      close $fh;
    }

    $targets{$ofile} = \@deps;
  }

  $dynamic_lib .= "\n";

  foreach my $target (sort keys %targets)
  {
    $dynamic_lib .= "$target : @{$targets{$target}}\n";
  }

  $dynamic_lib;
}

1;
