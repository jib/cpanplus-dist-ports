package CPANPLUS::Dist::Ports;

use strict;
use vars    qw[@ISA $STATUS];
@ISA =      qw[CPANPLUS::Dist];

use CPANPLUS::inc;
use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Dist::Constants::Ports;

use Config;
use FileHandle;
use File::Basename;
use File::Find;

use IPC::Cmd                    qw[run];
use Params::Check               qw[check];
use Module::Load::Conditional   qw[can_load check_install];
use Locale::Maketext::Simple    Class => 'CPANPLUS', Style => 'gettext';

local $Params::Check::VERBOSE = 1;

### XXX check if we're on freebsd? or perhaps we can do this cross-platform
sub format_available { return 1; }

sub init {
    my $self    = shift;
    my $status  = $self->status;

    $status->mk_accessors(qw[makefile distinfo pkg_descr pkg_plis distdir
                                make created installed uninstalled
                                _create_args _install_args] );
    return 1;
}

sub create {
    ### just in case you already did a create call for this module object
    ### just via a different dist object
    my $dist = shift;
    my $self = $dist->parent;
    $dist    = $self->status->dist   if      $self->status->dist;
    $self->status->dist( $dist )     unless  $self->status->dist;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    ### there's a good chance the module has only been extracted so far,
    ### so let's go and build it first
    {   my $builder = CPANPLUS::Dist->new(
                            module  => $self,
                            format  => $self->status->installer_type
                        );
        unless( $builder ) {
            error( loc( q[Could not create a dist for '%1' with ] .
                        q[installer type '%2'], $self->module,
                        $self->status->installer_type ) );
            $dist->status->created(0);
            return;
        }

        unless( $builder->create(%hash, prereq_format => 'ports' ) ) {
            $dist->status->created(0);
            return;
        }
    }
    ### ok, all should be set now, let's go on building our own
    ### distribution now

    my $dir;
    unless( $dir = $self->status->extract ) {
        error( loc( "No dir found to operate on!" ) );
        return;
    }

    my $args;
    my( $force,$verbose,$make,$makeflags,$perl,$builddir,$portsdir,$category,
        $prefix, $distdir, $prereq_target );
    {   local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            verbose     => { default => $conf->get_conf('verbose'),
                                store => \$verbose },
            force       => { default => $conf->get_conf('force'),
                                store => \$force },
            makeflags   => { default => $conf->get_conf('makeflags'),
                                store => \$makeflags },
            make        => { default => $conf->get_program('make'),
                                store => \$make },
            perl        => { default => ($conf->get_program('perl') || $^X),
                                store => \$perl },
            builddir    => { default => $self->status->extract,
                                store => \$builddir },
            portsdir    => { default => PORTS_DIR,      store => \$portsdir },
            category    => { default => PORTS_CATEGORY, store => \$category },
            prefix      => { default => PORTS_PREFIX,   store => \$prefix },
            distdir     => { default => '',             store => \$distdir },

            ### XXX is this the right thing to do???
            prereq_target   => { default => 'install',
                                 store   => \$prereq_target },
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    ### the directory we'll put the ports files in ###
    $distdir ||= File::Spec->catdir(
                        $conf->get_conf('base'),
                        $cb->_perl_version( perl => $perl ),
                        $conf->_get_build('distdir'),
                        'ports',
                        $category,
                        $prefix . $self->package_name
                    );

    ### create the path ###
    unless( -d $distdir ) {
        unless( $cb->_mkdir( dir => $distdir ) ) {
            error( loc("Could not create directory '%1'", $distdir ) );
            $dist->status->created(0);
            return;
        }
    }

    ### chdir to it ###
    unless( $cb->_chdir( dir => $distdir ) ) {
        $dist->status->created(0);
        return;
    }

    $dist->status->distdir( $distdir );

    ### find where prereqs landed, etc.. add them to our dependency list ###
    my @depends;
    {   my $prereqs = $self->status->prereqs;
        for my $prereq ( sort keys %$prereqs ) {
            my $obj = $cb->module_tree($prereq);

            unless( $obj ) {
                error( loc( "Couldn't find module object for prerequisite ".
                            "'%1' -- skipping", $prereq ) );
                next;
            }

            ### no point in listing prereqs that are IN the perl core
            ### themselves
            next if $obj->package_is_perl_core;

            ### XXX perhaps we should see if this port already exists
            ### in the regular /usr/ports/ collections first?
            ### but how do we know if the version is any good? --kane

            ### check if we have the file required somewhere already ###
            ### XXX use constants for the placeholders? ###
            my $map = [
                [ installsitearch => '${SITE_PERL}/${PERL_ARCH}' ],
                [ installsitelib  => '${SITE_PERL}',             ],
                [ installarchlib  => '' ],  # part of core perl
                [ installprivlib  => '' ],  # skippable too
            ];

            my $pm = $obj->module; $pm =~ s|::|/|g; $pm .= '.pm';

            my $local_dir;
            for my $aref (@$map) {
                my ($type,$placeholder) = @$aref;
                $local_dir = $placeholder
                        if -e File::Spec->catfile($Config{$type}, $pm);

                last if $local_dir;
            }

            ### fine, we'll guess then ###
            $local_dir ||= '${SITE_PERL}';

            push @depends,  "$local_dir/$pm:\${PORTSDIR}/" . PORTS_CATEGORY .
                            '/'. PORTS_PREFIX . $obj->package_name;
        }
    }

    ### Get all the meta data for the makefile, then write it ###
    {   my $makefile = MAKEFILE->($distdir);

        ### open the makefile for writing ###
        my $fh;
        unless( $fh = FileHandle->new( ">$makefile" ) ) {
            error( loc( "Could not open '%1' for writing: %2",
                         $makefile, $! ) );
            $dist->status->created(0);
            return;
        }

        ### the subdir on the cpan mirror we can find the distribution ###
        my $subdir  = PORTS_SUBDIR->( $self->path );
        my $date    = PORTS_DATE;
        my $blib    = BLIB->( $builddir );
        my @man1    = PORTS_MAN1->($blib);
        my @man3    = PORTS_MAN3->($blib);
        my $desc    = $self->description || $self->module;
        my $name    = $self->package_name;
        my $email   = $conf->get_conf('email');
        my $version = $self->package_version;   # NOT the module version!
        my $depends = join(" \\\n\t\t", @depends);
        my $inst    = $self->status->installer_type eq 'makemaker'
                        ? 'PERL_CONFIGURE=	yes'
                        : 'PERL_MODBUILD=	yes';

        $fh->print(<< "EOF");
# New ports collection makefile for:	$category/$prefix$name
# Date created:				$date
# Whom:					CPANPLUS User $email
#
# \$FreeBSD \$
#

PORTNAME=	$name
PORTVERSION=	$version
CATEGORIES=	$category perl5
MASTER_SITES=	\${MASTER_SITE_PERL_CPAN}
MASTER_SITE_SUBDIR=	$subdir
PKGNAMEPREFIX=	$prefix

MAINTAINER=	$email
COMMENT=	$desc

# dependencies
BUILD_DEPENDS=	$depends
RUN_DEPENDS=	\${BUILD_DEPENDS}

# installer to use; Module::Build or MakeMaker
$inst

# always install into the site dir
# otherwise, ports get unhappy and install into wrong directories
CONFIGURE_ARGS+=    INSTALLDIRS='site'

EOF

        $fh->print("MAN1=		@man1\n") if @man1;
        $fh->print("MAN3=		@man3\n") if @man3;
        $fh->print("\n".PORTS_INCLUDE_BSD_MK."\n");

        $fh->close;

        $dist->status->makefile( $makefile );
    }


    ### get all the metadata for distinfo file and write it ###
    {   my $distinfo    = PORTS_DISTINFO->($distdir);

        my $fh;
        unless( $fh = FileHandle->new( ">$distinfo" ) ) {
            error( loc( "Could not open '%1' for writing: %2",
                        $distinfo, $! ) );
            $dist->status->created(0);
            return;
        }

        my $use_list = { 'Digest::MD5' => '0.0' };

        ### no digest::md5 ? ###
        unless( can_load( modules => $use_list ) ) {
            error( loc( "Unable to compute a checksum of the ".
                        "archive due to missing '%1' -- cannot continue",
                        'Digest::MD5' ) );
            $dist->status->created(0);
            return;
        }

        ### compute the md5 again ourselves ###
        my $archive = $self->status->fetch;

        my $md5_fh;
        unless( $md5_fh = FileHandle->new($archive) ) {
            error( loc( "Could not open '%1' for reading: %2",
                        $archive, $! ) );
            $dist->status->created(0);
            return;
        }

        binmode $md5_fh;

        my $digest = Digest::MD5->new;
        $digest->addfile( $md5_fh );
        my $md5 = $digest->hexdigest;

        ### actually write the file ###
        $fh->print( "MD5 (". $self->package .") = $md5\n" );
        $fh->print( "SIZE (".$self->package .") = ".
                    (-s $self->status->fetch) ."\n");

        close $fh;

        $dist->status->distinfo( $distinfo );
    }

    ### write the description file ###
    {   my $desc    = PORTS_PKG_DESCR->($distdir);

        my $fh;
        unless( $fh = FileHandle->new( ">$desc" ) ) {
            error( loc( "Could not open '%1' for writing: %2",
                        $desc, $! ) );
            $dist->status->created(0);
            return;
        }

        $fh->print( "# This space intentionally left blank.\n" );

        close $fh;

        $dist->status->pkg_descr( $desc );
    }

    ### write the plist file ###
    {   my $plist   = PORTS_PKG_PLIST->($distdir);

        my $fh;
        unless( $fh = FileHandle->new( ">$plist" ) ) {
            error( loc( "Could not open '%1' for writing: %2",
                        $plist, $! ) );
            $dist->status->created(0);
            return;
        }

        my $blib = BLIB->($self->status->extract);

        ### find scripts ###
        File::Find::find( sub {
            print $fh "bin/$_\n" if -f and $_ ne DOT_EXISTS;
        }, PORTS_SCRIPT_DIR->($blib) ) if -d PORTS_SCRIPT_DIR->($blib);

        ### XXX autrijus, what's with the archdir/archroot stuff?

        ### find files and directories in the 'ARCH' tree ###
        my (@arch, %archdir, %archroot);
        File::Find::find( sub {
            my $f = substr( $File::Find::name, (length($blib)+1) );
            if( -f $File::Find::name ) {
                push @arch, $f;
                $archdir{ substr( $File::Find::dir, (length($blib)+1) ) }++
            } else {
                $archroot{ $f }++ if -d $File::Find::name;
            }
        }, ARCH_DIR->($blib) ) if -d ARCH_DIR->($blib);

        ### find files and directories in the 'LIB' tree ###
        my (@lib, %libdir, %libroot);
        File::Find::find( sub {
            my $e = DOT_EXISTS; return if /^$e/;
            my $f = substr( $File::Find::name, (length($blib)+1) );
            if( -f $File::Find::name ) {
                push @lib, $f;
                $libdir{ substr($File::Find::dir, (length($blib)+1) ) }++
            } else {
                $libroot{ $f }++ if -d $File::Find::name;
            }
        }, LIB_DIR->($blib) ) if -d LIB_DIR->($blib);

        my $have_arch = @arch > 1 ? 1 : 0;

        ### now start munging the paths so they can go in the plist file ###
        {   my $psp         = PORTS_SITE_PERL;
            my $ppa         = PORTS_PERL_ARCH;
            my $lib         = LIB_DIR->();
            my $arch        = ARCH_DIR->();
            my $lib_auto    = LIB_AUTO_DIR->();
            my $arch_auto   = ARCH_AUTO_DIR->();

            ### do @lib first ###
            for my $file (sort @lib) {
                my $rep = $have_arch ? $ppa : $psp;
                $file =~ s|^$lib|$rep|;
                print $fh "$file\n";
            }

            ### next, go through @arch ###
            for my $file (sort @arch) {

                ### XXX why is this? --kane
                substr($file, -6) = PORTS_PACKLIST
                    if substr($file, -7) eq DOT_EXISTS;

                $file =~ s|^$arch|$ppa|;
                print $fh "$file\n";
            }

            ### unlink @libdir ###
            for my $dir (sort { length $b <=> length $a or
                                $a cmp $b } keys %libdir
            ) {
                ### XXX why?
                delete $libroot{$dir};
                next if $dir eq $lib or $dir =~ m!^$lib_auto!;

                my $rep = $have_arch ? $ppa : $psp;
                $dir =~ s|^$lib|$rep|;
                print $fh "\@dirrm $dir\n";
            }

            ### unlink @archdir ###
            for my $dir (sort { length $b <=> length $a or
                                $a cmp $b } keys %archdir
            ) {
                ### XXX why?
                delete $archroot{$dir};
                $dir =~ s|^$lib|$ppa|;
                print $fh "\@dirrm $dir\n";
            }

             ### unlink @libroot
            for my $dir (sort { length $b <=> length $a or
                                $a cmp $b } keys %libroot
            ) {
                next if $dir eq $lib or $dir =~ m!^$lib_auto!;

                my $rep = $have_arch ? $ppa : $psp;
                $dir =~ s|^$lib|$rep|;
                print $fh "\@unexec rmdir %D/$dir 2>/dev/null || true\n";
            }

            ### unlink @archroot
            for my $dir (sort { length $b <=> length $a or
                                $a cmp $b } keys %archroot
            ) {
                next if $dir eq $arch or $dir eq $arch_auto;
                $dir =~ s|^$arch|$ppa|;
                print $fh "\@unexec rmdir %D/$dir 2>/dev/null || true\n";
            }
        }

        $fh->close;
        $dist->status->pkg_plist($plist);
    }

    return $dist->status->created(1);
}

sub install {
    ### just in case you already did a create call for this module object
    ### just via a different dist object
    my $dist = shift;
    my $self = $dist->parent;
    $dist    = $self->status->dist   if      $self->status->dist;
    $self->status->dist( $dist )     unless  $self->status->dist;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my ($make, $verbose, $target, $flags);
    my $tmpl = {
        make    => {default => $conf->get_program('make'), store => \$make},
        verbose => {default => $conf->get_conf('verbose'), store => \$verbose},
        target  => {default => 'reinstall', store => \$target },
        flags   => {default => ['-DFORCE_PKG_REGISTER'],
                    store => \$flags},
    };

    check( $tmpl, \%hash ) or return;

    ### find out where we put all the files ###
    my $distdir;
    unless( $distdir = $dist->status->distdir ) {
        error( loc( "Don't know where your distdir is for '%1' ".
                    "-- perhaps you need to run 'create' first?",
                    $self->module ) );
        $dist->status->installed(0);
        return;
    }

    ### go there ###
    unless( $cb->_chdir(dir => $distdir) ) {
        error( loc( "Could not chdir to '%1' -- cannot continue",
                    $distdir ) );

        $dist->status->installed(0);
        return;
    }

    ### run the command ###
    my $sudo    = $conf->get_program('sudo');
    my @cmd     = ($make, $target, @$flags);
    unshift @cmd, $sudo if $sudo;

    my $buffer;
    unless( scalar run( command => \@cmd,
                        verbose => $verbose,
                        buffer  => \$buffer )
    ) {
        error( loc( "An error occurred installing '%1': %2",
                    $self->module, $buffer ) );
        $dist->status->installed(0);
        return;
    }

    return $dist->status->installed(1);
};

1;

# Local variables:
# c-indentation-style: bsd
# c-basic-offset: 4
# indent-tabs-mode: nil
# End:
# vim: expandtab shiftwidth=4:


