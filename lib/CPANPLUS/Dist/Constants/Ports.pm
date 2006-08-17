package CPANPLUS::Dist::Constants::Ports;

use strict;
use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use File::Spec;
use Locale::Maketext::Simple    Class => 'CPANPLUS', Style => 'gettext';

BEGIN {

    require Exporter;
    use vars    qw[$VERSION @ISA @EXPORT];
  
    $VERSION    = 0.01;
    @ISA        = qw[Exporter];
    @EXPORT     = qw[   PORTS_DIR PORTS_CATEGORY PORTS_PREFIX PORTS_DATE 
                        PORTS_SUBDIR PORTS_MAN1 PORTS_MAN3 PORTS_INCLUDE_BSD_MK
                        PORTS_DISTINFO PORTS_PKG_PLIST PORTS_PKG_DESCR
                        PORTS_SCRIPT_DIR PORTS_SITE_PERL PORTS_PERL_ARCH
                        PORTS_PACKLIST
                ];
}

use constant PORTS_DIR          => '/usr/ports';
use constant PORTS_CATEGORY     => 'devel';
use constant PORTS_PREFIX       => 'p5-';
use constant PORTS_DATE         =>  join(' ',
                                        (split(/\s+/,scalar gmtime))[1,2,-1]);
use constant PORTS_SUBDIR       => sub { "../../" . shift() }; 

use constant PORTS_MAN1         => sub {my $blib = shift; 
                                        map File::Basename::basename($_),
                                            <$blib/man1/*.1> };

use constant PORTS_MAN3         => sub {my $blib = shift; 
                                        map File::Basename::basename($_),
                                            <$blib/man3/*.3> };
                                            
use constant PORTS_INCLUDE_BSD_MK       
                                => '.include <bsd.port.mk>';

use constant PORTS_DISTINFO     => sub { return @_
                                        ? File::Spec->catfile(
                                                shift(),'distinfo')
                                        : 'distinfo'; };
                                        
use constant PORTS_PKG_DESCR    => sub { return @_
                                        ? File::Spec->catfile(
                                                shift(),'pkg-descr')
                                        : 'pkg-descr'; };

use constant PORTS_PKG_PLIST    => sub { return @_
                                        ? File::Spec->catfile(
                                                shift(),'pkg-plist')
                                        : 'pkg-plist'; };                                        

use constant PORTS_SCRIPT_DIR   => sub { return @_
                                        ? File::Spec->catdir(
                                                shift(),'script')
                                        : 'script'; };   

use constant PORTS_SITE_PERL    => '%%SITE_PERL%%';
use constant PORTS_PERL_ARCH    => PORTS_SITE_PERL.'/%%PERL_ARCH%%';
use constant PORTS_PACKLIST     => 'packlist';

1;
