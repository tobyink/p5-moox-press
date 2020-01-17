use 5.008008;
use strict;
use warnings;

package MooX::Press;

our $AUTHORITY = 'cpan:TOBYINK';
our $VERSION   = '0.024';

use Types::Standard 1.008003 -is, -types;
use Types::TypeTiny qw(ArrayLike HashLike);
use Exporter::Tiny qw(mkopt);
use namespace::autoclean;

# Options not to carry up into subclasses;
# mostly because subclasses inherit behaviour anyway.
my @delete_keys = qw(
	subclass
	has
	with
	extends
	factory
	coerce
	around
	before
	after
	type_name
	can
	type_library_can
	factory_package_can
);

my $_handle_list = sub {
	my ($thing) = @_;
	return ()
		unless defined $thing;
	return $thing
		if is_Str $thing;
	return %$thing
		if is_HashRef $thing;
	return @$thing
		if is_ArrayRef $thing;
	goto $thing
		if is_CodeRef $thing;
	die "Unexepcted thing; got $thing";
};

my $_handle_list_add_nulls = sub {
	my ($thing) = @_;
	return map @$_, @{mkopt $thing}
		if is_ArrayRef $thing;
	goto $_handle_list;
};

my %_cached_moo_helper;

sub import {
	my $builder = shift;
	my $caller  = caller;
	my %opts    = @_==1 ? shift->$_handle_list_add_nulls : @_;
	$opts{caller}  ||= $caller;
	$opts{toolkit} ||= $ENV{'PERL_MOOX_PRESS_TOOLKIT'} || 'Moo';
	
	$opts{version} = $opts{caller}->VERSION
		unless exists $opts{version};
	$opts{authority} = do { no strict 'refs'; no warnings 'once'; ${$opts{caller}."::AUTHORITY"} }
		unless exists $opts{authority};
	
	$opts{prefix}          = $opts{caller} unless exists $opts{prefix};
	$opts{factory_package} = $opts{prefix} unless exists $opts{factory_package};
	
	$builder->munge_options(\%opts);
	
	my @role_generators  = @{ mkopt $opts{role_generator} };
	my @class_generators = @{ mkopt $opts{class_generator} };
	my @roles            = @{ mkopt $opts{role} };
	my @classes          = @{ mkopt $opts{class} };
	
	# Canonicalize these now, saves repeatedly doing it later!
	for my $pkg (@role_generators) {
		if (is_CodeRef($pkg->[1])
		or  is_HashRef($pkg->[1]) && is_CodeRef($pkg->[1]{code})) {
			$pkg->[1] = { generator => $pkg->[1] };
		}
		$pkg->[1] = { $pkg->[1]->$_handle_list };
		$builder->munge_role_generator_options($pkg->[1], \%opts);
	}
	for my $pkg (@class_generators) {
		if (is_CodeRef($pkg->[1])
		or  is_HashRef($pkg->[1]) && is_CodeRef($pkg->[1]{code})) {
			$pkg->[1] = { generator => $pkg->[1] };
		}
		$pkg->[1] = { $pkg->[1]->$_handle_list };
		$builder->munge_class_generator_options($pkg->[1], \%opts);
	}
	for my $pkg (@roles) {
		$pkg->[1] = { $pkg->[1]->$_handle_list };
		$builder->munge_role_options($pkg->[1], \%opts);
	}
	for my $pkg (@classes) {
		$pkg->[1] = { $pkg->[1]->$_handle_list };
		if (defined $pkg->[1]{extends} and not ref $pkg->[1]{extends}) {
			$pkg->[1]{extends} = [$pkg->[1]{extends}];
		}
		$builder->munge_class_options($pkg->[1], \%opts);
	}

	unless (exists $opts{type_library}) {
		$opts{type_library} = 'Types';
		$opts{type_library} = $builder->qualify_name($opts{type_library}, $opts{prefix});
	}
	
	if ($opts{type_library}) {
		$builder->prepare_type_library($opts{type_library}, %opts);
		# no type for role generators
		for my $pkg (@class_generators) {
			$builder->make_type_for_class_generator($pkg->[0], %opts, %{$pkg->[1]});
		}
		for my $pkg (@roles) {
			$builder->make_type_for_role($pkg->[0], %opts, %{$pkg->[1]});
		}
		for my $pkg (@classes) {
			$builder->make_type_for_class($pkg->[0], %opts, %{$pkg->[1]});
		}
	}
	
	my $reg;
	if ($opts{factory_package}) {
		require Type::Registry;
		$reg = 'Type::Registry'->for_class($opts{factory_package});
		$reg->add_types($_) for (
			$opts{type_library},
			qw( Types::Standard Types::Common::Numeric Types::Common::String Types::TypeTiny ),
		);
	}
	
	{
		my %methods;
		my $method_installer = $opts{toolkit_install_methods} || ("install_methods");
		
		%methods = delete($opts{factory_package_can})->$_handle_list_add_nulls;
		$builder->$method_installer($opts{'factory_package'}||$opts{'caller'}, \%methods) if keys %methods;
		
		%methods = delete($opts{type_library_can})->$_handle_list_add_nulls;
		$builder->$method_installer($opts{type_library}, \%methods) if keys %methods;
	}
	
	for my $pkg (@roles) {
		$builder->do_coercions_for_role($pkg->[0], %opts, reg => $reg, %{$pkg->[1]});
	}
	for my $pkg (@classes) {
		$builder->do_coercions_for_class($pkg->[0], %opts, reg => $reg, %{$pkg->[1]});
	}
	
	for my $pkg (@class_generators) {
		$builder->make_class_generator($pkg->[0], %opts, %{$pkg->[1]});
	}
	for my $pkg (@role_generators) {
		$builder->make_role_generator($pkg->[0], %opts, %{$pkg->[1]});
	}
	for my $pkg (@roles) {
		$builder->make_role($pkg->[0], %opts, %{$pkg->[1]});
	}
	for my $pkg (@classes) {
		$builder->make_class($pkg->[0], %opts, %{$pkg->[1]});
	}
	
	%_cached_moo_helper = ();  # cleanups
}

sub munge_options {
	my $builder = shift;
	my ($opts) = @_;
	for my $key (sort keys %$opts) {
		if ($key =~ /^(class|role|class_generator|role_generator):([^:].*)$/) {
			my ($kind, $pkg) = ($1, $2);
			my $val = delete $opts->{$key};
			if (ref $val) {
				push @{ $opts->{$kind} ||= [] }, $pkg, $val;
			}
			elsif ($val eq 1 or not defined $val) {
				push @{ $opts->{$kind} ||= [] }, $pkg;
			}
			else {
				$builder->croak("$kind\:$pkg shortcut should be '1' or reference");
			}
		}
	}
	return;
}

sub munge_role_options {
	shift;
	my ($roleopts, $opts) = @_;
	return;
}

sub munge_class_options {
	shift;
	my ($classopts, $opts) = @_;
	return;
}

sub munge_class_generator_options {
	shift;
	my ($cgenopts, $opts) = @_;
	return;
}

sub munge_role_generator_options {
	shift;
	my ($rgenopts, $opts) = @_;
	return;
}

sub qualify_name {
	shift;
	my ($name, $prefix, $parent) = @_;
	my $sigil = "";
	if ($name =~ /^[@%\$]/) {
		$sigil = substr $name, 0, 1;
		$name  = substr $name, 1;
	}
	return $sigil.join("::", $parent->$_handle_list, $1) if (defined $parent and $name =~ /^\+(.+)/);
	return $sigil.$1 if $name =~ /^::(.+)$/;
	$prefix ? $sigil.join("::", $prefix, $name) : $sigil.$name;
}

sub type_name {
	shift;
	my ($name, $prefix) = @_;
	my $stub = $name;
	if (lc substr($name, 0, length $prefix) eq lc $prefix) {
		$stub = substr($name, 2 + length $prefix);
	}
	$stub =~ s/::/_/g;
	$stub;
}

sub croak {
	shift;
	require Carp;
	goto \&Carp::croak;
}

my $none;
sub prepare_type_library {
	my $builder = shift;
	my ($lib, %opts) = @_;
	my ($version, $authority) = ($opts{version}, $opts{authority});
	my %types_hash;
	require Type::Tiny::Role;
	require Type::Tiny::Class;
	require Type::Registry;
	eval "package $lib; use Type::Library -base; 1"
		or $builder->croak("Could not prepare type library $lib: $@");
	require Module::Runtime;
	$INC{ Module::Runtime::module_notional_filename($lib) } = __FILE__;
	my $adder = sub {
		my $me = shift;
		my ($name, $kind, $target, $coercions) = @_;
		my $tc_class = 'Type::Tiny::' . ucfirst($kind);
		my $tc_obj   = $tc_class->new(
			name     => $name,
			library  => $me,
			$kind    => $target,
		);
		$types_hash{$kind}{$target} = $tc_obj;
		$me->add_type($tc_obj);
		Type::Registry->for_class($opts{factory_package})->add_type($tc_obj)
			if defined $opts{factory_package};
		if ($coercions) {
			$none ||= ~Any;
			$tc_obj->coercion->add_type_coercions($none, 'die()');
		}
	};
	my $getter = sub {
		my $me = shift;
		my ($kind, $target) = @_;
		if ($target =~ /^([@%])(.+)$/) {
			my $sigil = $1;
			$target = $2;
			if ($sigil eq '@') {
				return ArrayRef->of($types_hash{$kind}{$target})
					if $types_hash{$kind}{$target};
			}
			elsif ($sigil eq '%') {
				return HashRef->of($types_hash{$kind}{$target})
					if $types_hash{$kind}{$target};
			}
		}
		$types_hash{$kind}{$target};
	};
	if (defined $opts{'factory_package'} or not exists $opts{'factory_package'}) {
		require B;
		eval(
			sprintf '
				package %s;
				sub type_library { %s };
				sub get_type_for_package { shift->type_library->get_type_for_package(@_) };
				1;
			',
			$opts{'factory_package'}||$opts{'caller'},
			B::perlstring($lib),
		) or $builder->croak("Could not install type library methods into factory package: $@");
	}
	no strict 'refs';
	no warnings 'once';
	*{"$lib\::_mooxpress_add_type"} = $adder;
	*{"$lib\::get_type_for_package"} = $getter;
	${"$lib\::VERSION"} = $version if defined $version;
	${"$lib\::AUTHORITY"} = $authority if defined $authority;
}

sub make_type_for_role {
	my $builder = shift;
	my ($name, %opts) = @_;
	return unless $opts{'type_library'};
	$builder->croak("Roles ($name) cannnot extend things") if $opts{extends};
	$builder->_make_type($name, %opts, is_role => 1);
}

sub make_type_for_class {
	my $builder = shift;
	my ($name, %opts) = @_;
	return unless $opts{'type_library'};
	$builder->_make_type($name, %opts, is_role => 0);
}

sub make_type_for_class_generator {
	my $builder = shift;
	my ($name, %opts) = @_;
	my $qname = $builder->qualify_name($name, $opts{prefix});

	if ($opts{'type_library'}) {
		my $class_type_name = $opts{'class_type_name'}
			|| sprintf('%sClass', $builder->type_name($qname, $opts{'prefix'}));
		my $class_type = $opts{'type_library'}->add_type({
			name        => $class_type_name,
			parent      => ClassName,
			constraint  => sprintf('$_->can("GENERATOR") && ($_->GENERATOR eq %s)', B::perlstring($qname)),
		});
		
		my $instance_type_name = $opts{'instance_type_name'}
			|| sprintf('%sInstance', $builder->type_name($qname, $opts{'prefix'}));
		my $instance_type = $opts{'type_library'}->add_type({
			name        => $instance_type_name,
			parent      => Object,
			constraint  => sprintf('$_->can("GENERATOR") && ($_->GENERATOR eq %s)', B::perlstring($qname)),
		});
		
		if ($opts{'factory_package'}) {
			my $reg = Type::Registry->for_class($opts{'factory_package'});
			$reg->add_type($_) for $class_type, $instance_type;
		}
	}
}

sub _make_type {
	my $builder = shift;
	my ($name, %opts) = @_;
	my $qname = $builder->qualify_name($name, $opts{prefix}, $opts{extends});
	
	my $type_name = $opts{'type_name'} || $builder->type_name($qname, $opts{'prefix'});
	if ($opts{'type_library'}->can('_mooxpress_add_type')) {
		$opts{'type_library'}->_mooxpress_add_type(
			$type_name,
			$opts{is_role} ? 'role' : 'class',
			$qname,
			!!$opts{coerce},
		);
	}
	
	if (defined $opts{'subclass'} and not $opts{'is_role'}) {
		my @subclasses = $opts{'subclass'}->$_handle_list_add_nulls;
		while (@subclasses) {
			my ($sc_name, $sc_opts) = splice @subclasses, 0, 2;
			my %opts_clone = %opts;
			delete $opts_clone{$_} for @delete_keys;
			$builder->make_type_for_class($sc_name, %opts_clone, extends => "::$qname", $sc_opts->$_handle_list);
		}
	}
}

sub do_coercions_for_role {
	my $builder = shift;
	my ($name, %opts) = @_;
	$builder->_do_coercions($name, %opts, is_role => 1);
}

sub do_coercions_for_class {
	my $builder = shift;
	my ($name, %opts) = @_;
	$builder->_do_coercions($name, %opts, is_role => 0);
}

sub _do_coercions {
	my $builder = shift;
	my ($name, %opts) = @_;
	
	my $qname = $builder->qualify_name($name, $opts{prefix}, $opts{extends});
	
	if ($opts{coerce}) {
		my $method_installer = $opts{toolkit_install_methods} || ("install_methods");
		my @coercions = @{$opts{'coerce'} || []};
		
		while (@coercions) {
			my $type = shift @coercions;
			if (!ref $type) {
				my $tc = $opts{reg}->lookup($type);
				$type = $tc if $tc;
			}
			my $method_name = shift @coercions;
			defined($method_name) && !ref($method_name)
				or $builder->croak("No method name found for coercion to $qname from $type");
			
			my $coderef;
			$coderef = shift @coercions if is_CodeRef $coercions[0];

			my $mytype;
			if ($opts{type_library}) {
				$mytype = $opts{type_library}->get_type_for_package($opts{'is_role'} ? 'role' : 'class', $qname);
			}
			
			if ($coderef) {
				$builder->$method_installer($qname, { $method_name => $coderef });
			}
			
			if ($mytype) {
				require B;
				$mytype->coercion->add_type_coercions($type, sprintf('%s->%s($_)', B::perlstring($qname), $method_name));
			}
		}
	}
	
	if (defined $opts{'subclass'} and not $opts{'is_role'}) {
		my @subclasses = $opts{'subclass'}->$_handle_list_add_nulls;
		while (@subclasses) {
			my ($sc_name, $sc_opts) = splice @subclasses, 0, 2;
			my %opts_clone = %opts;
			delete $opts_clone{$_} for @delete_keys;
			$builder->do_coercions_for_class($sc_name, %opts_clone, extends => "::$qname", $sc_opts->$_handle_list);
		}
	}
}

sub make_role {
	my $builder = shift;
	my ($name, %opts) = @_;
	$builder->_make_package($name, %opts, is_role => 1);
}

sub make_class {
	my $builder = shift;
	my ($name, %opts) = @_;
	$builder->_make_package($name, %opts, is_role => 0);
}

sub make_role_generator {
	my $builder = shift;
	my ($name, %opts) = @_;
	$builder->_make_package_generator($name, %opts, is_role => 1);
}

sub make_class_generator {
	my $builder = shift;
	my ($name, %opts) = @_;
	$builder->_make_package_generator($name, %opts, is_role => 0);
}

sub _expand_isa {
	my ($builder, $pfx, $ext) = @_;
	my @raw = $ext->$_handle_list;
	my @isa;
	my $changed;
	while (@raw) {
		if (@raw > 1 and ref($raw[1])) {
			my $gen  = $builder->qualify_name(shift(@raw), $pfx);
			my @args = shift(@raw)->$_handle_list;
			push @isa, sprintf('::%s', $gen->generate_package(@args));
			$changed++;
		}
		else {
			push @isa, shift(@raw);
		}
	}
	@$ext = @isa if $changed;;
	map $builder->qualify_name($_, $pfx), @isa;
}

my $nondeep;
sub _make_package {
	my $builder = shift;
	my ($name, %opts) = @_;
	
	my @isa = $opts{extends} ? $builder->_expand_isa($opts{prefix}, $opts{extends}) : ();
	my $qname = $builder->qualify_name($name, $opts{prefix}, @isa);
	my $tn = $builder->type_name($qname, $opts{prefix});
	
	if (!exists $opts{factory}) {
		$opts{factory} = 'new_' . lc $tn;
	}
	
	my $toolkit = {
		moo    => 'Moo',
		moose  => 'Moose',
		mouse  => 'Mouse',
	}->{lc $opts{toolkit}} || $opts{toolkit};
	
	if ($opts{is_role}) {
		eval "package $qname; use $toolkit\::Role; use namespace::autoclean; 1"
			or $builder->croak("Could not create package $qname: $@");
	}
	else {
		my $optthing = '';
		if ($toolkit eq 'Moo' and $INC{'Type/Tiny.pm'} and eval { require MooX::TypeTiny; 1 }) {
			$optthing = ' use MooX::TypeTiny;';
		}
		elsif ($toolkit eq 'Moose' and eval { require MooseX::XSAccessor; 1 }) {
			$optthing = ' use MooseX::XSAccessor;';
		}
		eval "package $qname; use $toolkit;$optthing use namespace::autoclean; 1"
			or $builder->croak("Could not create package $qname: $@");
	
		my $method  = $opts{toolkit_extend_class} || ("extend_class_".lc $toolkit);
		if (@isa) {
			$builder->$method($qname, \@isa);
		}
	}
	
	my $reg;
	if ($opts{factory_package}) {
		require Type::Registry;
		'Type::Registry'->for_class($qname)->set_parent(
			'Type::Registry'->for_class($opts{factory_package})
		);
		$reg = 'Type::Registry'->for_class($qname);
	}
	
	for my $var (qw/VERSION AUTHORITY/) {
		if (defined $opts{lc $var}) {
			no strict 'refs';
			no warnings 'once';
			${"$qname\::$var"} = $opts{lc $var};
		}
	}
	
	if (ref $opts{'begin'}) {
		$opts{'begin'}->($qname, $opts{is_role} ? 'role' : 'class');
	}
	
	{
		my $method = $opts{toolkit_apply_roles} || ("apply_roles_".lc $toolkit);
		my @roles = $opts{with}->$_handle_list;
		if (@roles) {
			my @processed;
			while (@roles) {
				if (@roles > 1 and ref($roles[1])) {
					my $gen  = $builder->qualify_name(shift(@roles), $opts{prefix});
					my @args = shift(@roles)->$_handle_list;
					push @processed, $gen->generate_package(@args);
				}
				else {
					push @processed, $builder->qualify_name(shift(@roles), $opts{prefix});
				}
			}
			$builder->$method($qname, \@processed);
		}
	}
	
	my $method_installer = $opts{toolkit_install_methods} || ("install_methods");
	{
		my %methods;
		%methods = $opts{can}->$_handle_list_add_nulls;
		$builder->$method_installer($qname, \%methods) if keys %methods;
		%methods = $opts{factory_package_can}->$_handle_list_add_nulls;
		$builder->$method_installer($opts{'factory_package'}||$opts{'caller'}, \%methods) if keys %methods;
		%methods = $opts{type_library_can}->$_handle_list_add_nulls;
		$builder->$method_installer($opts{type_library}, \%methods) if keys %methods;
	}
	
	{
		my $method = $opts{toolkit_install_constants} || ("install_constants");
		my %methods = $opts{constant}->$_handle_list_add_nulls;
		if (keys %methods) {
			$builder->$method($qname, \%methods);
		}
	}
	
	{
		my $method = $opts{toolkit_make_attribute} || ("make_attribute_".lc $toolkit);
		my @attrs = $opts{has}->$_handle_list_add_nulls;
		#use Data::Dumper;
		#warn Dumper(\@attrs);
		while (@attrs) {
			my ($attrname, $attrspec) = splice @attrs, 0, 2;
			
			my %spec_hints;
			if ($attrname =~ /^(\+?)(\$|\%|\@)(.+)$/) {
				$spec_hints{isa} ||= {
					'$' => ($nondeep ||= ((~ArrayRef)&(~HashRef))),
					'@' => ArrayLike,
					'%' => HashLike,
				}->{$2};
				no warnings 'uninitialized';
				$attrname = $1.$3; # allow plus before sigil
			}
			if ($attrname =~ /^(.+)\!$/) {
				$spec_hints{required} = 1;
				$attrname = $1;
			}
			
			(my $buildername = "_build_$attrname") =~ s/\+//;
			(my $clearername = ($attrname =~ /^_/ ? "_clear$attrname" : "clear_$attrname")) =~ s/\+//;
			
			my %spec =
				is_CodeRef($attrspec) ? (is => 'rw', lazy => 1, builder => $attrspec, clearer => $clearername) :
				is_Object($attrspec) && $attrspec->can('check') ? (is => 'rw', isa => $attrspec) :
				$attrspec->$_handle_list_add_nulls; # ????? should not add nulls ?????
			if (is_CodeRef $spec{builder}) {
				my $code = delete $spec{builder};
				$spec{builder} = $buildername;
				$builder->$method_installer($qname, { $buildername => $code });
			}
			
			%spec = (%spec_hints, %spec);
			$spec{is} ||= 'rw';
			
			if ($spec{does}) {
				my $target = $builder->qualify_name(delete($spec{does}), $opts{prefix});
				$spec{isa} ||= do {
					$opts{type_library}
						? $opts{type_library}->get_type_for_package(role => $target)
						: undef;
				};
				$spec{isa} ||= do {
					ConsumerOf->of($target);
				};
			}
			if ($spec{isa} && !ref $spec{isa}) {
				my $target = $builder->qualify_name(delete($spec{isa}), $opts{prefix});
				$spec{isa} ||= do {
					$opts{type_library}
						? $opts{type_library}->get_type_for_package(class => $target)
						: undef;
				};
				$spec{isa} ||= do {
					InstanceOf->of($target);
				};
			}
			if ($spec{enum}) {
				$spec{isa} = Enum->of(@{delete $spec{enum}});
			}
			if (is_Object($spec{type}) and $spec{type}->can('check')) {
				$spec{isa} = delete $spec{type};
			}
			elsif ($spec{type}) {
				$spec{isa} = $reg->lookup(delete $spec{type});
			}
			
			if (ref $spec{isa} && !exists $spec{coerce} && $spec{isa}->has_coercion) {
				$spec{coerce} = 1;
			}
			
			$builder->$method($qname, $attrname, \%spec);
		}
	}

	if ($opts{is_role}) {
		my $method   = $opts{toolkit_require_methods} || ("require_methods_".lc $toolkit);
		my %requires = $opts{requires}->$_handle_list_add_nulls;
		if (keys %requires) {
			$builder->$method($qname, \%requires);
		}
	}

	for my $modifier (qw(before after around)) {
		my $method = $opts{toolkit_modify_methods} || ("modify_method_".lc $toolkit);
		my @methods = $opts{$modifier}->$_handle_list;
		while (@methods) {
			my @method_names;
			push(@method_names, shift @methods)
				while (@methods and not ref $methods[0]);
			my $coderef = $builder->_prepare_method_modifier($qname, $modifier, \@method_names, shift(@methods));
			$builder->$method($qname, $modifier, \@method_names, $coderef);
		}
	}
	
	unless ($opts{is_role}) {
		
		if ($toolkit eq 'Moose' && !$opts{'mutable'}) {
			require Moose::Util;
			Moose::Util::find_meta($qname)->make_immutable;
		}
		
		if (defined $opts{'factory_package'} or not exists $opts{'factory_package'}) {
			my $fpackage = $opts{'factory_package'} || $opts{'caller'};
			if ($opts{'factory'}) {
				my @methods = $opts{'factory'}->$_handle_list;
				while (@methods) {
					my @method_names;
					push(@method_names, shift @methods)
						while (@methods and not ref $methods[0]);
					my $coderef = shift(@methods) || \"new";
					for my $name (@method_names) {
						if (is_CodeRef $coderef) {
							eval "package $fpackage; sub $name :method { splice(\@_, 1, 0, '$qname'); goto \$coderef }; 1"
								or $builder->croak("Could not create factory $name in $fpackage: $@");
						}
						elsif (is_ScalarRef $coderef) {
							my $target = $$coderef;
							eval "package $fpackage; sub $name :method { shift; '$qname'->$target\(\@_) }; 1"
								or $builder->croak("Couldn't create factory $name in $fpackage: $@");
						}
						elsif (is_HashRef $coderef) {
							my %meta = %$coderef;
							$meta{curry} ||= [$qname];
							$builder->$method_installer($fpackage, { $name => \%meta });
						}
						else {
							die "lolwut?";
						}
					}
				}
			}
			eval "sub $qname\::FACTORY { '$fpackage' }; 1"
				or $builder->croak("Couldn't create link back to factory $qname\::FACTORY: $@");
		}
		
		if (defined $opts{'subclass'}) {
			my @subclasses = $opts{'subclass'}->$_handle_list_add_nulls;
			while (@subclasses) {
				my ($sc_name, $sc_opts) = splice @subclasses, 0, 2;
				my %opts_clone = %opts;
				delete $opts_clone{$_} for @delete_keys;
				$builder->make_class($sc_name, %opts_clone, extends => "::$qname", $sc_opts->$_handle_list);
			}
		}
	}
	
	if (ref $opts{'end'}) {
		$opts{'end'}->($qname, $opts{is_role} ? 'role' : 'class');
	}
	
	if ($opts{type_library}) {
		my $mytype = $opts{type_library}->get_type_for_package($opts{'is_role'} ? 'role' : 'class', $qname);
		$mytype->coercion->freeze if $mytype;
	}
	
	return $qname;
}

sub _make_package_generator {
	my $builder = shift;
	my ($name, %opts) = @_;
	my $gen = $opts{generator} or die 'no generator code given!';
	
	my $kind = $opts{is_role} ? 'role' : 'class';
	
	my $qname = $builder->qualify_name($name, $opts{prefix});
	my $method_installer = $opts{toolkit_install_methods} || ("install_methods");
	
	$builder->$method_installer(
		$qname,
		{
			'_generate_package_spec' => $gen,
			'generate_package' => sub {
				my ($generator_package, @args) = @_;
				$builder->generate_package(
					$kind,
					$generator_package,
					\%opts,
					$generator_package->_generate_package_spec(@args),
				);
			},
		},
	);
	
	if ($opts{factory_package}) {
		my $tn = $builder->type_name($qname, $opts{prefix});
		if (!exists $opts{factory}) {
			$opts{factory} = 'generate_' . lc $tn;
		}
		my $fp = $opts{factory_package};
		my $f  = $opts{factory};
		eval qq{
			package $fp;
			sub $f :method {
				shift;
				q($qname)->generate_package(\@_);
			}
		};
	}
	
	return $qname;
}

my %_generate_counter;
sub generate_package {
	my $builder           = shift;
	my $kind              = shift;
	my $generator_package = shift;
	my $global_opts       = shift;
	my %local_opts        = ( @_ == 1 ? $_[0] : \@_ )->$_handle_list;
	
	my %opts;
	for my $key (qw/ extends with has can constant around before after
		toolkit version authority mutable begin end requires /) {
		if (exists $local_opts{$key}) {
			$opts{$key} = delete $local_opts{$key};
		}
	}
	
	if (keys %local_opts) {
		die "bad keys from generator: ".join(", ", sort keys %local_opts);
	}
	
	# must not generate types or factory methods
	$opts{factory}   = undef;
	$opts{type_name} = undef;
	
	$_generate_counter{$generator_package} = 0 unless exists $_generate_counter{$generator_package};
	my $qname = sprintf('%s::__GEN%06d__', $generator_package, ++$_generate_counter{$generator_package});
	
	if ($global_opts->{factory_package}) {
		require Type::Registry;
		'Type::Registry'->for_class($qname)->set_parent(
			'Type::Registry'->for_class($global_opts->{factory_package})
		);
	}
	
	if ($kind eq 'class') {
		my $method = $opts{toolkit_install_constants} || ("install_constants");
		$builder->$method($qname, { GENERATOR => $generator_package });
	}
	
	if ($kind eq 'role') {
		return $builder->make_role("::$qname", %$global_opts, %opts);
	}
	else {
		return $builder->make_class("::$qname", %$global_opts, %opts);
	}
}

sub _get_moo_helper {
	my $builder = shift;
	my ($package, $helpername) = @_;
	return $_cached_moo_helper{"$package\::$helpername"}
		if $_cached_moo_helper{"$package\::$helpername"};
	die "lolwut?" unless $helpername =~ /^(has|with|extends|around|before|after|requires)$/;
	my $is_role = ($INC{'Moo/Role.pm'} && 'Moo::Role'->is_role($package));
	my $tracker = $is_role ? $Moo::Role::INFO{$package}{exports} : $Moo::MAKERS{$package}{exports};
	if (ref $tracker) {
		$_cached_moo_helper{"$package\::$helpername"} ||= $tracker->{$helpername};
	}
	# I hate this...
	$_cached_moo_helper{"$package\::$helpername"} ||= eval sprintf(
		'do { package %s; use Moo%s; my $coderef = \&%s; no Moo%s; $coderef };',
		$package,
		$is_role ? '::Role' : '',
		$helpername,
		$is_role ? '::Role' : '',
	);
	die "BADNESS: couldn't get helper '$helpername' for package '$package'" unless $_cached_moo_helper{"$package\::$helpername"};
	$_cached_moo_helper{"$package\::$helpername"};
}

sub make_attribute_moo {
	my $builder = shift;
	my ($class, $attribute, $spec) = @_;
	my $helper = $builder->_get_moo_helper($class, 'has');
	if (is_Object($spec->{isa}) and $spec->{isa}->isa('Type::Tiny::Enum') and $spec->{handles}) {
		$builder->_process_enum_moo(@_);
	}
	$helper->($attribute, %$spec);
}

sub _process_enum_moo {
	my $builder = shift;
	my ($class, $attribute, $spec) = @_;
	require MooX::Enumeration;
	my %new_spec = 'MooX::Enumeration'->process_spec($class, $attribute, %$spec);
	if (delete $new_spec{moox_enumeration_process_handles}) {
		'MooX::Enumeration'->install_delegates($class, $attribute, \%new_spec);
	}
	%$spec = %new_spec;
}

sub make_attribute_moose {
	my $builder = shift;
	my ($class, $attribute, $spec) = @_;
	if (is_Object($spec->{isa}) and $spec->{isa}->isa('Type::Tiny::Enum')||$spec->{isa}->isa('Moose::Meta::TypeConstraint::Enum') and $spec->{handles}) {
		$builder->_process_enum_moose(@_);
	}
	require Moose::Util;
	(Moose::Util::find_meta($class) or $class->meta)->add_attribute($attribute, $spec);
}

sub _process_enum_moose {
	my $builder = shift;
	my ($class, $attribute, $spec) = @_;
	require MooseX::Enumeration;
	push @{ $spec->{traits}||=[] }, 'Enumeration';
}

sub make_attribute_mouse {
	my $builder = shift;
	my ($class, $attribute, $spec) = @_;
	use Data::Dumper;
	print Dumper($spec);
	if (is_Object($spec->{isa}) and $spec->{isa}->isa('Type::Tiny::Enum') and $spec->{handles}) {
		$builder->_process_enum_mouse(@_);
	}
	require Mouse::Util;
	(Mouse::Util::find_meta($class) or $class->meta)->add_attribute($attribute, $spec);
}

sub _process_enum_mouse {
	die 'not implemented';
}

sub extend_class_moo {
	my $builder = shift;
	my ($class, $isa) = @_;
	my $helper = $builder->_get_moo_helper($class, 'extends');
	$helper->(@$isa);
}

sub extend_class_moose {
	my $builder = shift;
	my ($class, $isa) = @_;
	require Moose::Util;
	(Moose::Util::find_meta($class) or $class->meta)->superclasses(@$isa);
}

sub extend_class_mouse {
	my $builder = shift;
	my ($class, $isa) = @_;
	require Mouse::Util;
	(Mouse::Util::find_meta($class) or $class->meta)->superclasses(@$isa);
}

{
	my $_process_roles = sub {
		my ($r, $tk) = @_;
		map {
			my $role = $_;
			if ($role =~ /\?$/) {
				$role =~ s/\?$//;
				eval "require $role; 1"
					or eval "package $role; use $tk\::Role; 1";
			}
			$role;
		} @$r;
	};
	
	sub apply_roles_moo {
		my $builder = shift;
		my ($class, $roles) = @_;
		my $helper = $builder->_get_moo_helper($class, 'with');
		$helper->($roles->$_process_roles('Moo'));
	}

	sub apply_roles_moose {
		my $builder = shift;
		my ($class, $roles) = @_;
		require Moose::Util;
		Moose::Util::ensure_all_roles($class, $roles->$_process_roles('Moose'));
	}

	sub apply_roles_mouse {
		my $builder = shift;
		my ($class, $roles) = @_;
		require Mouse::Util;
		# this can double-apply roles? :(
		Mouse::Util::apply_all_roles($class, $roles->$_process_roles('Mouse'));
	}
}

sub require_methods_moo {
	my $builder = shift;
	my ($role, $methods) = @_;
	my $helper = $builder->_get_moo_helper($role, 'requires');
	$helper->(sort keys %$methods);
}

sub require_methods_moose {
	my $builder = shift;
	my ($role, $methods) = @_;
	require Moose::Util;
	(Moose::Util::find_meta($role) or $role->meta)->add_required_methods(sort keys %$methods);
}

sub require_methods_mouse {
	my $builder = shift;
	my ($role, $methods) = @_;
	require Mouse::Util;
	(Mouse::Util::find_meta($role) or $role->meta)->add_required_methods(sort keys %$methods);
}

sub install_methods {
	my $builder = shift;
	my ($class, $methods) = @_;
	for my $name (sort keys %$methods) {
		no strict 'refs';
		my ($coderef, $signature, $signature_style, $invocant_count, @curry);
		
		if (is_CodeRef($methods->{$name})) {
			$coderef = $methods->{$name};
			$signature_style = 'code';
		}
		elsif (is_HashRef($methods->{$name})) {
			$coderef   = $methods->{$name}{code};
			$signature = $methods->{$name}{signature};
			@curry     = @{ $methods->{$name}{curry} || [] };
			$invocant_count  = exists($methods->{$name}{invocant_count}) ? $methods->{$name}{invocant_count} : 1;
			$signature_style = $methods->{$name}{named} ? 'named' : 'positional';
		}
		
		my $ok;
		if ($signature) {
			$signature_style eq 'code'
				? CodeRef->assert_valid($signature)
				: ArrayRef->assert_valid($signature);
			
			$ok = eval qq{
				package $class;
				my \$check;
				sub $name :method {
					my \@invocants = splice(\@_, 0, $invocant_count);
					\$check ||= q($builder)->_build_method_signature_check(q($class), q($class\::$name), \$signature_style, \$signature, \\\@invocants);
					\@_ = (\@invocants, \@curry, \&\$check);
					goto \$coderef;
				};
				1;
			};
		}
		else {
			# Why use a wrapper? Because don't want to rename coderefs with Sub::Name.
			# Why not rename? Because it could be installed into multiple packages.
			$ok = eval "package $class; sub $name :method { goto \$coderef }; 1";
		}
		
		$ok or $builder->croak("Could not create method $name in package $class: $@");
	}
}

# need to partially parse stuff for Type::Params to look up type names
sub _build_method_signature_check {
	my $builder = shift;
	my ($method_class, $method_name, $signature_style, $signature) = @_;
	my $type_library;
	my @sig = @$signature;
	
	return $signature if $signature_style eq 'code';
	
	require Type::Params;
	
	my $global_opts = {};
	$global_opts = shift(@sig) if is_HashRef($sig[0]) && !$sig[0]{slurpy};
	
	$global_opts->{subname} ||= $method_name;
	
	my $is_named = ($signature_style eq 'named');
	my @params;
	
	my $reg;
	
	while (@sig) {
		if (is_HashRef($sig[0]) and $sig[0]{slurpy}) {
			push @params, shift @sig;
			die "lolwut? after slurpy? you srs?" if @sig;
		}
		
		my ($name, $type, $opts) = (undef, undef, {});
		if ($is_named) {
			($name, $type) = splice(@sig, 0, 2);
		}
		else {
			$type = shift(@sig);
		}
		if (is_HashRef($sig[0]) && !ref($sig[0]{slurpy})) {
			$opts = shift(@sig);
		}
		
		# All that work, just to do this!!!
		if (is_Str($type) and not $type =~ /^[01]$/) {
			$reg ||= do {
				require Type::Registry;
				'Type::Registry'->for_class($method_class);
			};
			
			if ($type =~ /^\%/) {
				$type = HashRef->of(
					$reg->lookup(substr($type, 1))
				);
			}
			elsif ($type =~ /^\@/) {
				$type = ArrayRef->of(
					$reg->lookup(substr($type, 1))
				);
			}
			else {
				$type = $reg->lookup($type);
			}
		}
		
		my $hide_opts = 0;
		if ($opts->{slurpy} && !ref($opts->{slurpy})) {
			delete $opts->{slurpy};
			$type = { slurpy => $type };
			$hide_opts = 1;
		}
		
		push(
			@params,
			$is_named
				? ($name, $type, $hide_opts?():($opts))
				: (       $type, $hide_opts?():($opts))
		);
	}
	
	my $next = $is_named ? \&Type::Params::compile_named_oo : \&Type::Params::compile;
	@_ = ($global_opts, @params);
	goto($next);
}

sub install_constants {
	my $builder = shift;
	my ($class, $methods) = @_;
	for my $name (sort keys %$methods) {
		no strict 'refs';
		my $value = $methods->{$name};
		if (defined $value && !ref $value) {
			require B;
			my $stringy = B::perlstring($value);
			eval "package $class; sub $name () { $stringy }; 1"
				or $builder->croak("Could not create constant $name in package $class: $@");
		}
		else {
			eval "package $class; sub $name () { \$value }; 1"
				or $builder->croak("Could not create constant $name in package $class: $@");
		}
	}
}

sub _prepare_method_modifier {
	my ($builder, $class, $kind, $names, $method) = @_;
	return $method if is_CodeRef $method;
	
	my $coderef   = $method->{code};
	my $signature = $method->{signature};
	my @curry     = @{ $method->{curry} || [] };
	my $signature_style = $method->{named} ? 'named' : 'positional';
	
	my $invocant_count = 1 + !!($kind eq 'around');
	$invocant_count  = $method->{invocant_count} if exists $method->{invocant_count};
	
	my $name = join('|', @$names)."($kind)";

	my $wrapped = eval qq{
		my \$check;
		sub {
			my \@invocants = splice(\@_, 0, $invocant_count);
			\$check ||= q($builder)->_build_method_signature_check(q($class), q($class\::$name), \$signature_style, \$signature, \\\@invocants);
			\@_ = (\@invocants, \@curry, \&\$check);
			goto \$coderef;
		};
	};
	$wrapped or die("YIKES: $@");
}

sub modify_method_moo {
	my $builder = shift;
	my ($class, $modifier, $method_names, $coderef) = @_;
	my $helper = $builder->_get_moo_helper($class, $modifier);
	$helper->(@$method_names, $coderef);
}

sub modify_method_moose {
	my $builder = shift;
	my ($class, $modifier, $method_names, $coderef) = @_;
	my $m = "add_$modifier\_method_modifier";
	require Moose::Util;
	my $meta = Moose::Util::find_meta($class) || $class->meta;
	for my $method_name (@$method_names) {
		$meta->$m($method_name, $coderef);
	}
}

sub modify_method_mouse {
	my $builder = shift;
	my ($class, $modifier, $method_names, $coderef) = @_;
	my $m = "add_$modifier\_method_modifier";
	require Mouse::Util;
	my $meta = (Mouse::Util::find_meta($class) or $class->meta);
	for my $method_name (@$method_names) {
		$meta->$m($method_name, $coderef);
	}
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

MooX::Press - quickly create a bunch of Moo/Moose/Mouse classes and roles

=head1 SYNOPSIS

  package MyApp;
  use Types::Standard qw(Str Num);
  use MooX::Press (
    role => [
      'Livestock',
      'Pet',
      'Milkable' => {
        can => [
          'milk' => sub { print "giving milk\n"; },
        ],
      },
    ],
    class => [
      'Animal' => {
        has => [
          'name'   => Str,
          'colour',
          'age'    => Num,
          'status' => { enum => ['alive', 'dead'], default => 'alive' },
        ],
        subclass => [
          'Panda',
          'Cat'  => { with => ['Pet'] },
          'Dog'  => { with => ['Pet'] },
          'Cow'  => { with => ['Livestock', 'Milkable'] },
          'Pig'  => { with => ['Livestock'] },
        ],
      },
    ],
  );

Using your classes:

  use MyApp;
  
  my $kitty = MyApp->new_cat(name => "Grey", status => "alive");
  # or:       MyApp::Cat->new(name => "Grey", status => "alive");
  
  MyApp->new_cow(name => "Daisy")->milk();

I realize this is a longer synopsis than most CPAN modules give, but
considering it sets up six classes and three roles with some attributes
and methods, applies the roles to the classes, and creates a type library
with nine types in it, it's pretty concise.

=head1 DESCRIPTION

L<MooX::Press> (pronounced "Moo Express") is a quick way of creating a bunch
of simple Moo classes and roles at once without needing to create separate
Perl modules for each class and each role, and without needing to add a bunch
of boilerplate to each file.

It also supports Moose and Mouse, though Moo classes and roles play nicely
with Moose (and to a certain extent with Mouse) anyway.

=head2 Import Options

MooX::Press is called like:

  use MooX::Press %import_opts;

The following options are supported. To make these easier to remember, options
follow the convention of using lower-case singular, and reusing keywords from
Perl and Moo/Moose/Mouse when possible.

=over

=item C<< class >> I<< (OptList) >>

This is the list of classes to create as an optlist. An optlist is an arrayref
of strings, where each string is optionally followed by a reference.

  [ "A", "B", "C", \%opt_for_C, "D", "E", \%opts_for_E, "F" ]

In particular, for the class optlist the references should be hashrefs of
class options (see L</Class Options>), though key-value pair arrayrefs are
also accepted.

=item C<< role >> I<< (OptList) >>

This is the list of roles to create, structured almost the same as the optlist
for classes, but see L</Role Options>.

=item C<< class_generator >> I<< (OptList) >>

Kind of like C<class>, but:

  [ "A", \&generator_for_A, "B", \&generator_for_B, ... ]

"A" and "B" are not classes, but when C<< MyApp->generate_a(...) >>
is called, it will pass arguments to C<< &generator_for_A >> which is expected
to return a hashref like C<< \%opts_for_A >>. Then a new pseudononymous class
will be created with those options.

See the FAQ for an example.

=item C<< role_generator >> I<< (OptList) >>

The same but for roles.

See the FAQ for an example.

=item C<< toolkit >> I<< (Str) >>

The strings "Moo", "Moose", or "Mouse" are accepted and instruct MooX::Press
to use your favourite OO toolkit. "Moo" is the default.

=item C<< version >> I<< (Num) >>

This has nothing to do with the version of MooX::Press you are using.
It sets the C<< our $VERSION >> variable for the classes and roles being
generated.

=item C<< authority >> I<< (Str) >>

This sets the C<< our $AUTHORITY >> variable for the classes and roles being
generated.

C<version> and C<authority> will be copied from the caller if they are not set,
but you can set them to undef explicitly if you want to avoid that.

=item C<< prefix >> I<< (Str|Undef) >>

A namespace prefix for MooX::Press to put all your classes into. If MooX::Press
is told to create a class "Animal" and C<prefix> is set to "MyApp::OO", then
it will create a class called "MyApp::OO::Animal".

This is optional and defaults to the caller. If you wish to have no prefix,
then pass an explicit C<< prefix => undef >> option.

You can bypass the prefix for a specific class or a specific role using a
leading double colon, like "::Animal".

=item C<< factory_package >> I<< (Str|Undef) >>

A package name to install methods like the C<new_cat> and C<new_cow> methods
in L</SYNOPSIS>.

This defaults to prefix, but may be explicitly set to undef to suppress the
creation of such methods.

In every class (but not role) that MooX::Press builds, there will be a
C<FACTORY> method created so that, for example

  MyApp::Cow->FACTORY  # returns "MyApp"

=item C<< type_library >> I<< (Str|Undef) >>

MooX::Press will automatically create a L<Type::Library>-based type library
with type constraints for all your classes and roles. It will be named using
your prefix followed by "::Types".

You can specify a new name or explicitly set to undef to suppress this
behaviour, but a lot of the coercion features of MooX::Press rely on there
being a type library.

MooX::Press will create a get_type_for_package method that allows you to
do this:

  MyApp::Types->get_type_for_package(class => "MyApp::Animal")

MooX::Press will mark "MyApp/Types.pm" as loaded in %INC, so you can do
things like:

  use MyApp::Types qw(Animal);

And it won't complain about "MyApp/Types.pm" not being found.

MooX::Press will install a C<type_library> method into the factory package
which returns the name of the type library, so you can do:

  MyApp->type_library->get_type_for_package(class => "MyApp::Animal")

=item C<< caller >> I<< (Str) >>

MooX::Press determines some things based on which package called it. If you
are wrapping MooX::Press, you can fake the caller by passing it as an option.

=item C<< end >> I<< (CodeRef) >>

After creating each class or role, this coderef will be called. It will be
passed two parameters; the fully-qualified package name of the class or role,
plus the string "class" or "role" as appropriate.

Optional; defaults to nothing.

=item C<< begin >> I<< (CodeRef) >>

Like C<end>, but called before setting up any attributes, methods, or
method modifiers. (But after loading Moo/Moose/Mouse.)

Optional; defaults to nothing.

=item C<< mutable >> I<< (Bool) >>

Boolean to indicate that classes should be left mutable after creating them
rather than making them immutable. Constructors for mutable classes are
considerably slower than for immutable classes, so this is usually a bad
idea.

Only supported for Moose. Unnecessary for Moo anyway. Defaults to false.

=item C<< factory_package_can >> I<< (HashRef[CodeRef]) >>

Hashref of additional subs to install into the factory package.

=item C<< type_library_can >> I<< (HashRef[CodeRef]) >>

Hashref of additional subs to install into the factory package.

=back

At this top level, a shortcut is available for the 'class' and 'role' keys.
Rather than:

  use MooX::Press (
    role => [
      'Quux',
      'Quuux' => { ... },
    ],
    class => [
      'Foo',
      'Bar' => { ... },
      'Baz' => { ... },
    ],
  );

It is possible to write:

  use MooX::Press (
    'role:Quux'  => {},
    'role:Quuux' => { ... },
    'class:Foo'  => {},
    'class:Bar'  => { ... },
    'class:Baz'  => { ... },
  );

This saves a level of indentation. (C<< => undef >> or C<< => 1 >> are
supported as synonyms for C<< => {} >>.)

=head3 Class Options

Each class in the list of classes can be followed by a hashref of
options:

  use MooX::Press (
    class => [
      'Foo' => \%options_for_foo,
      'Bar' => \%options_for_bar,
    ],
  );

The following class options are supported.

=over

=item C<< extends >> I<< (Str|ArrayRef[Str]) >>

The parent class for this class.

The prefix is automatically added. Include a leading "::" if you
don't want the prefix to be added.

Multiple inheritance is supported.

=item C<< with >> I<< (ArrayRef[Str]) >>

Roles for this class to consume.

The prefix is automatically added. Include a leading "::" if you don't
want the prefix to be added.

Roles may include a trailing "?". When these are seen, the role will be
created if it doesn't seem to exist. This is because sometimes it's useful
to have roles to classify classes (and check them with the C<does> method)
even if those roles don't have any other functionality.

  use MooX::Press (
    prefix => 'Farm',
    class  => [
      'Sheep' => { with => ['Bleat?'] },
    ],
  );
  
  if (Farm::Sheep->new->does('Farm::Bleat')) {
    ...;
  }

Without the "?", trying to compose a role that does not exist is an error.

=item C<< has >> I<< (OptList) >>

The list of attributes to add to the class as an optlist.

The strings are the names of the attributes, but these strings may be
"decorated" with sigils and suffixes:

=over

=item C<< $foo >>

Creates an attribute "foo" intended to hold a single value.
This adds a type constraint forbidding arrayrefs and hashrefs
but allowing any other value, including undef, strings, numbers,
and any other reference.

=item C<< @foo >>

Creates an attribute "foo" intended to hold a list of values.
This adds a type constraint allowing arrayrefs or objects
overloading C<< @{} >>.

=item C<< %foo >>

Creates an attribute "foo" intended to hold a collection of key-value
pairs. This adds a type constraint allowing hashrefs or objects
overloading C<< %{} >>.

=item C<< foo! >>

Creates an attribute "foo" which will be required by the constructor.

=back

An attribute can have both a sigil and a suffix.

The references in the optlist may be attribute specification hashrefs,
type constraint objects, or builder coderefs.

  # These mean the same thing...
  "name!" => Str,
  "name"  => { is => "rw", required => 1, isa => Str },

  # These mean the same thing...
  "age"   => sub { return 0 },
  "age"   => {
    is         => "rw",
    lazy       => 1,
    builder    => sub { return 0 },
    clearer    => "clear_age",
  },

Type constraints can be any blessed object supported by the toolkit. For
Moo, use L<Type::Tiny>. For Moose, use L<Type::Tiny>, L<MooseX::Types>,
or L<Specio>. For Mouse, use L<Type::Tiny> or L<MouseX::Types>.

Builder coderefs are automatically installed as methods like
"YourPrefix::YourClass::_build_age()".

For details of the hashrefs, see L</Attribute Specifications>.

=item C<< can >> I<< (HashRef[CodeRef|HashRef]) >>

A hashref of coderefs to install into the package.

  package MyApp;
  use MooX::Press (
    class => [
      'Foo' => {
         can => {
           'bar' => sub { print "in bar" },
         },
       },
    ],
  );
  
  package main;
  MyApp->new_foo()->bar();

As an alternative, you can do this to prevent your import from getting
cluttered with coderefs. Which you choose depends a lot on stylistic
preference.

  package MyApp;
  use MooX::Press (
    class => ['Foo'],
  );
  
  package MyApp::Foo;
  sub bar { print "in bar" },
  
  package main;
  MyApp->new_foo()->bar();

=item C<< constant >> I<< (HashRef[Item]) >>

A hashref of scalar constants to define in the package.

  package MyApp;
  use MooX::Press (
    class => [
      'Foo' => {
         constant => {
           'BAR' => 42,
         },
       },
    ],
  );
  
  package main;
  print MyApp::Foo::BAR, "\n";
  print MyApp->new_foo->BAR, "\n";

=item C<< around >> I<< (ArrayRef|HashRef) >>

=item C<< before >> I<< (ArrayRef|HashRef) >>

=item C<< after >> I<< (ArrayRef|HashRef) >>

Installs method modifiers.

  package MyApp;
  use MooX::Press (
    role => [
      'Loud' => {
        around => [
          'greeting' => sub {
            my $orig = shift;
            my $self = shift;
            return uc( $self->$orig(@_) );
          },
        ],
      }
    ],
    class => [
      'Person' => {
        can => {
          'greeting' => sub { "hello" },
        }
        subclass => [
          'LoudPerson' => { with => 'Loud' },
        ],
      },
    ],
  );
  
  package main;
  print MyApp::LoudPerson->new->greeting, "\n";  # prints "HELLO"

=item C<< coerce >> I<< (ArrayRef) >>

When creating a class or role "Foo", MooX::Press will also create a
L<Type::Tiny::Class> or L<Type::Tiny::Role> called "Foo". The C<coerce>
option allows you to add coercions to that type constraint. Coercions
are called as methods on the class or role. This is perhaps best
explained with an example:

  package MyApp;
  use Types::Standard qw(Str);
  use MooX::Press (
    class => [
      'Person' => {
        has    => [ 'name!' => Str ],
        can    => {
          'from_name' => sub {
            my ($class, $name) = @_;
            return $class->new(name => $name);
          },
        },
        coerce => [
          Str, 'from_name',
        ],
      },
      'Company' => {
        has    => [ 'name!' => Str, 'owner!' => { isa => 'Person' } ],
      },
    ],
  );

This looks simple but it's like the swan, graceful above the surface of the
water, legs paddling frantically below.

It creates a class called "MyApp::Person" with a "name" attribute, so you can
do this kind of thing:

  my $bob = MyApp::Person->new(name => "Bob");
  my $bob = MyApp->new_person(name => "Bob");

As you can see from the C<can> option, it also creates a method "from_name"
which can be used like this:

  my $bob = MyApp::Person->from_name("Bob");

But here's where coercions come in. It also creates a type constraint
called "Person" in "MyApp::Types" and adds a coercion from the C<Str> type.
The coercion will just call the "from_name" method.

Then when the "MyApp::Company" class is created and the "owner" attribute
is being set up, MooX::Press knows about the coercion from Str, and will
set up coercion for that attribute.

  # So this should just work...
  my $acme = MyApp->new_company(name => "Acme Inc", owner => "Bob");
  print $acme->owner->name, "\n";

Now that's out of the way, the exact structure for the arrayref of coercions
can be explained. It is essentially a list of type-method pairs.

The type may be either a blessed type constraint object (L<Type::Tiny>, etc)
or it may be a string type name for something that your type library knows
about.

The method is a string containing the method name to perform the coercion.

This may optionally be followed by coderef to install as the method. The
following two examples are equivalent:

  use MooX::Press (
    class => [
      'Person' => {
        has    => [ 'name!' => Str ],
        can    => {
          'from_name' => sub {
            my ($class, $name) = @_;
            return $class->new(name => $name);
          },
        },
        coerce => [
          Str, 'from_name',
        ],
      },
    ],
  );

  use MooX::Press (
    class => [
      'Person' => {
        has    => [ 'name!' => Str ],
        coerce => [
          Str, 'from_name' => sub {
            my ($class, $name) = @_;
            return $class->new(name => $name);
          },
        ],
      },
    ],
  );

In the second example, you can see the C<can> option to install the "from_name"
method has been dropped and the coderef put into C<coerce> instead.

In case it's not obvious, I suppose it's worth explicitly stating that it's
possible to have coercions from many different types.

  use MooX::Press (
    class => [
      'Foo::Bar' => {
        coerce => [
          Str,      'from_string', sub { ... },
          ArrayRef, 'from_array',  sub { ... },
          HashRef,  'from_hash',   sub { ... },
          'FBaz',   'from_foobaz', sub { ... },
        ],
      },
      'Foo::Baz' => {
        type_name => 'FBaz',
       },
    ],
  );

You should generally order the coercions from most specific to least
specific. If you list "Num" before "Int", "Int" will never be used
because all integers are numbers.

There is no automatic inheritance for coercions because that does not make
sense. If C<< Mammal->from_string($str) >> is a coercion returning a
"Mammal" object, and "Person" is a subclass of "Mammal", then there's
no way for MooX::Press to ensure that when C<< Person->from_string($str) >>
is called, it will return a "Person" object and not some other kind of
mammal. If you want "Person" to have a coercion, define the coercion in the
"Person" class and don't rely on it being inherited from "Mammal".

=item C<< subclass >> I<< (OptList) >>

Set up subclasses of this class. This accepts an optlist like the class list.
It allows subclasses to be nested as deep as you like:

  package MyApp;
  use MooX::Press (
    class => [
      'Animal' => {
         has      => ['name!'],
         subclass => [
           'Fish',
           'Bird',
           'Mammal' => {
              can      => { 'lactate' => sub { ... } },
              subclass => [
                'Cat',
                'Dog',
                'Primate' => {
                  subclass => ['Monkey', 'Gorilla', 'Human'],
                },
              ],
           },
         ],
       },
    ];
  );
  
  package main;
  my $uncle = MyApp->new_human(name => "Bob");
  $uncle->isa('MyApp::Human');    # true
  $uncle->isa('MyApp::Primate');  # true
  $uncle->isa('MyApp::Mammal');   # true
  $uncle->isa('MyApp::Animal');   # true
  $uncle->isa('MyApp::Bird');     # false
  $uncle->can('lactate');         # eww, but true

We just defined a nested heirarchy with ten classes there!

Subclasses can be named with a leading "+" to tell them to use their parent
class name as a prefix. So, in the example above, if you'd called your
subclasses "+Mammal", "+Dog", etc, you'd end up with packages like
"MyApp::Animal::Mammal::Dog". (In cases of multiple inheritance, it uses
C<< $ISA[0] >>.)

=item C<< factory >> I<< (Str|ArrayRef|Undef) >>

This is the name for the method installed into the factory package.
So for class "Cat", it might be "new_cat".

The default is the class name (excluding the prefix), lowercased,
with double colons replaced by single underscores, and
with "new_" added in front. To suppress the creation
of this method, set C<factory> to an explicit undef.

If set to an arrayref, it indicates you wish to create multiple
methods in the factory package to make objects of this class.

  factory => [
    "grow_pig"                         => \"new_from_embryo",
    "new_pork", "new_bacon", "new_ham" => sub { ... },
    "new_pig", "new_swine",
  ],

A scalarref indicates the name of a constructor and that the
methods before are shortcuts for that constructor. So
C<< MyApp->grow_pig(@args) >> is a shortcut for
C<< MyApp::Pig->new_from_embryo(@args) >>.

A coderef will have a custom method installed into the factory package
so that C<< MyApp->new_pork(@args) >> will act as a shortcut for:
C<< $coderef->("MyApp", "MyApp::Pig", @args) >>. Note that C<new_bacon>
and C<new_ham> are just aliases for C<new_bacon>.

The C<new_pig> and C<new_swine> method names are followed by
neither a coderef nor a scalarref, so are treated as if they had
been followed by C<< \"new" >>.

=item C<< type_name >> I<< (Str) >>

The name for the type being installed into the type library.

The default is the class name (excluding the prefix), with
double colons replaced by single underscores.

This:

  use MooX::Press prefix => "ABC::XYZ", class => ["Foo::Bar"];

Will create class "ABC::XYZ::Foo::Bar", a factory method
C<< ABC::XYZ->new_foo_bar() >>, and a type constraint
"Foo_Bar" in type library "ABC::XYZ::Types".

=item C<< toolkit >> I<< (Str) >>

Override toolkit choice for this class and any child classes.

=item C<< version >> I<< (Num) >>

Override version number for this class and any child classes.

=item C<< authority >> I<< (Str) >>

Override authority for this class and any child classes.

See L</Import Options>.

=item C<< prefix >> I<< (Str) >>

Override namespace prefix for this class and any child classes.

See L</Import Options>.

=item C<< factory_package >> I<< (Str) >>

Override factory_package for this class and any child classes.

See L</Import Options>.

=item C<< mutable >> I<< (Bool) >>

Override mutability for this class and any child classes.

See L</Import Options>.

=item C<< end >> I<< (CodeRef) >>

Override C<end> for this class and any child classes.

See L</Import Options>.

=item C<< begin >> I<< (CodeRef) >>

Override C<begin> for this class and any child classes.

  use MooX::Press::Keywords qw( true false );
  use MooX::Press (
    prefix => 'Library',
    class  => [
      'Book' => {
        begin => sub {
          my $classname = shift;   # "Library::Book"
          my $registry  = Type::Registry->for_class($classname);
          $registry->alias_type('ArrayRef[Str]' => 'StrList')
        },
        has => {
          'title'   => { type => 'Str',     required => true },
          'authors' => { type => 'StrList', required => true },
        },
      },
    ],
  );

See L</Import Options>.

=back

=head3 Role Options

Options for roles are largely the same as for classes with the following
exceptions:

=over

=item C<< requires >> I<< (ArrayRef) >>

A list of methods required by the role.

  package MyApp;
  use MooX::Press (
    role => [
      'Milkable' => {
        requires => ['get_udder'],
        ...,
      },
    ],
  );

Each method can optionally be followed by a method-defining hashref like
in C<can>:

  package MyApp;
  use MooX::Press (
    role => [
      'Milkable' => {
        requires => [
          'get_udder', { signature => [...], named => 0 },
        ],
        ...,
      },
    ],
  );

These hashrefs are currently ignored, but may be useful for people reading
your role declarations.

=item C<< extends >> I<< (Any) >>

This option is disallowed.

=item C<< can >> I<< (HashRef[CodeRef|HashRef]) >>

The alternative style for defining methods may cause problems with the order
in which things happen. Because C<< use MooX::Press >> happens at compile time,
the following might not do what you expect:

  package MyApp;
  use MooX::Press (
    role   => ["MyRole"],
    class  => ["MyClass" => { with => "MyRole" }],
  );
  
  package MyApp::MyRole;
  sub my_function { ... }

The "my_function" will not be copied into "MyApp::MyClass" because at the
time the class is constructed, "my_function" doesn't yet exist within the
role "MyApp::MyRole".

You can combat this by changing the order you define things in:

  package MyApp::MyRole;
  sub my_function { ... }
  
  package MyApp;
  use MooX::Press (
    role   => ["MyRole"],
    class  => ["MyClass" => { with => "MyRole" }],
  );

If you don't like having method definitions "above" MooX::Press in your file,
then you can move them out into a module.

  # MyApp/Methods.pm
  #
  package MyApp::MyRole;
  sub my_function { ... }

  # MyApp.pm
  #
  package MyApp;
  use MyApp::Methods (); # load extra methods
  use MooX::Press (
    role   => ["MyRole"],
    class  => ["MyClass" => { with => "MyRole" }],
  );

Or force MooX::Press to happen at runtime instead of compile time.

  package MyApp;
  require MooX::Press;
  import MooX::Press (
    role   => ["MyRole"],
    class  => ["MyClass" => { with => "MyRole" }],
  );
  
  package MyApp::MyRole;
  sub my_function { ... }
  
=item C<< subclass >> I<< (Any) >>

This option is silently ignored.

=item C<< factory >> I<< (Any) >>

This option is silently ignored.

=item C<< mutable >> I<< (Any) >>

This option is silently ignored.

=back

=head3 Attribute Specifications

Attribute specifications are mostly just passed to the OO toolkit unchanged,
somewhat like:

  has $attribute_name => %attribute_spec;

So whatever specifications (C<required>, C<trigger>, C<coerce>, etc) the
underlying toolkit supports should be supported.

The following are exceptions:

=over

=item C<< is >> I<< (Str) >>

This is optional rather than being required, and defaults to "rw".
(Yes, I prefer "ro" generally, but whatever.)

=item C<< isa >> I<< (Str|Object) >>

When the type constraint is a string, it is B<always> assumed to be a class
name and your application's namespace prefix is added. So
C<< isa => "HashRef" >> doesn't mean what you think it means. It means
an object blessed into the "YourApp::HashRef" class.

That is a feature though, not a weakness.

  use MooX::Press (
    prefix  => 'Nature',
    class   => [
      'Leaf'  => {},
      'Tree'  => {
        has  => {
          'nicest_leaf'  => { isa => 'Leaf' },
        },
      },
    ],
  );

The C<< Nature::Tree >> and C<< Nature::Leaf >> classes will be built, and
MooX::Press knows that the C<nicest_leaf> is supposed to be a blessed
C<< Nature::Leaf >> object.

String type names can be prefixed with C<< @ >> or C<< % >> to indicate an
arrayref or hashref of a type:

  use MooX::Press (
    prefix  => 'Nature',
    class   => [
      'Leaf'  => {},
      'Tree'  => {
        has  => {
          'foliage'  => { isa => '@Leaf' },
        },
      },
    ],
  );

For more everything else, use blessed type constraint objects, such as those
from L<Types::Standard>, or use C<type> as documented below.

  use Types::Standard qw( Str );
  use MooX::Press (
    prefix  => 'Nature',
    class   => [
      'Leaf'  => {},
      'Tree'  => {
        has  => {
          'foliage'  => { isa => '@Leaf' },
          'species'  => { isa => Str },
        },
      },
    ],
  );

=item C<< type >> I<< (Str) >>

C<< type => "HashRef" >> does what you think  C<< isa => "HashRef" >> should
do. More specifically it searches (by name) your type library, along with
L<Types::Standard>, L<Types::Common::Numeric>, and L<Types::Common::String>
to find the type constraint it thinks you wanted. It's smart enough to deal
with parameterized types, unions, intersections, and complements.

  use MooX::Press (
    prefix  => 'Nature',
    class   => [
      'Leaf'  => {},
      'Tree'  => {
        has  => {
          'foliage'  => { isa  => '@Leaf' },
          'species'  => { type => 'Str' },
        },
      },
    ],
  );

C<< type => $blessed_type_object >> does still work.

C<type> and C<isa> are basically the same as each other, but differ in
how they'll interpret a string. C<isa> assumes it's a class name as applies
the package prefix to it; C<type> assumes it's the name of a type constraint
which has been defined in some type library somewhere.

=item C<< coerce >> I<< (Bool) >>

MooX::Press automatically implies C<< coerce => 1 >> when you give a
type constraint that has a coercion. If you don't want coercion then
explicitly provide C<< coerce => 0 >>.

=item C<< does >> I<< (Str) >>

Similarly to C<isa>, these will be given your namespace prefix.

  # These mean the same...
  does => 'SomeRole',
  type => Types::Standard::ConsumerOf['MyApp::SomeRole'],

=item C<< enum >> I<< (ArrayRef[Str]) >>

This is a cute shortcut for an enum type constraint.

  # These mean the same...
  enum => ['foo', 'bar'],
  type => Types::Standard::Enum['foo', 'bar'],

If the type constraint is set to an enum and C<handles> is provided,
then MooX::Press will automatically load L<MooX::Enumeration> or
L<MooseX::Enumeration> as appropriate. (This is not supported for
Mouse.)

  use MooX::Press (
    prefix  => 'Nature',
    class   => [
      'Leaf'  => {
        has  => {
          'colour' => {
            enum    => ['green', 'red', 'brown'],
            handles => 2,
            default => 'green',
          },
        },
       },
    ],
  );
  
  my $leaf = Nature->new_leaf;
  if ( $leaf->colour_is_green ) {
    print "leaf is green!\n";
  }

=back

=head3 Method Signatures

Most places where a coderef is expected, MooX::Press will also accept a
hashref of the form:

  {
    signature  => [ ... ],
    named      => 1,
    code       => sub { ... },
  }

The C<signature> is a specification to be passed to C<compile> or
C<compile_named_oo> from L<Type::Params> (depending on whether C<named>
is true or false).

Unlike L<Type::Params>, these signatures allow type constraints to be
given as strings, which will be looked up by name.

This should work for C<can>, C<factory_can>, C<type_library_can>,
C<factory>, C<builder> methods, and method modifiers. (Though if you
are doing type checks in both the methods and method modifiers, this
may result in unnecessary duplication of checks.)

The invocant (C<< $self >>) is not included in the signature.
(For C<around> method modifiers, the original coderef C<< $orig >> is
logically a second invocant. For C<factory> methods installed in the
factory package, the factory package name and class name are both
considered invocants.) 

Example with named parameters:

  use MooX::Press (
    prefix => 'Wedding',
    class  => [
      'Person' => { has => [qw( $name $spouse )] },
      'Officiant' => {
        can => {
          'marry' => {
            signature => [ bride => 'Person', groom => 'Person' ],
            named     => 1,
            code      => sub {
              my ($self, $args) = @_;
              $args->bride->spouse($args->groom);
              $args->groom->spouse($args->bride);
              printf("%s, you may kiss the bride\n", $args->groom->name);
              return $self;
            },
          },
        },
      },
    ],
  );
  
  my $alice  = Wedding->new_person(name => 'Alice');
  my $bob    = Wedding->new_person(name => 'Robert');
  
  my $carol  = Wedding->new_officiant(name => 'Carol');
  $carol->marry(bride => $alice, groom => $bob);

Example with positional parameters:

  use MooX::Press (
    prefix => 'Wedding',
    class  => [
      'Person' => { has => [qw( $name $spouse )] },
      'Officiant' => {
        can => {
          'marry' => {
            signature => [ 'Person', 'Person' ],
            code      => sub {
              my ($self, $bride, $groom) = @_;
              $bride->spouse($groom);
              $groom->spouse($bride);
              printf("%s, you may kiss the bride\n", $groom->name);
              return $self;
            },
          },
        },
      },
    ],
  );
  
  my $alice  = Wedding->new_person(name => 'Alice');
  my $bob    = Wedding->new_person(name => 'Robert');
  
  my $carol  = Wedding->new_officiant(name => 'Carol');
  $carol->marry($alice, $bob);

Methods with a mixture of named and positional parameters are not supported.
If you really want such a method, don't provide a signature; just provide a
coderef and manually unpack C<< @_ >>.

=head2 Optimization Features

MooX::Press will automatically load L<MooX::TypeTiny> if it's installed,
which optimizes how Type::Tiny constraints and coercions are inlined into
Moo constructors. This is only used for Moo classes.

MooX::Press will automatically load L<MooseX::XSAccessor> if it's installed,
which speeds up some Moose accessors. This is only used for Moose classes.

=head2 Subclassing MooX::Press

All the internals of MooX::Press are called as methods, which should make
subclassing it possible.

  package MyX::Press;
  use parent 'MooX::Press';
  use Class::Method::Modifiers;
  
  around make_class => sub {
    my $orig = shift;
    my $self = shift;
    my ($name, %opts) = @_;
    ## Alter %opts here
    my $qname = $self->$orig($name, %opts);
    ## Maybe do something to the returned class
    return $qname;
  };

It is beyond the scope of this documentation to fully describe all the methods
you could potentially override, but here is a quick summary of some that may
be useful.

=over

=item C<< import(%opts|\%opts) >>

=item C<< qualify_name($name, $prefix) >>

=item C<< croak($error) >>

=item C<< prepare_type_library($qualified_name) >>

=item C<< make_type_for_role($name, %opts) >>

=item C<< make_type_for_class($name, %opts) >>

=item C<< make_role($name, %opts) >>

=item C<< make_class($name, %opts) >>

=item C<< install_methods($qualified_name, \%methods) >>

=item C<< install_constants($qualified_name, \%values) >>

=back

=head1 FAQ

This is a new module so I haven't had any questions about it yet, let alone
any frequently asked ones, but I will anticipate some.

=head2 Why doesn't MooX::Press automatically import strict and warnings for me?

Your MooX::Press import will typically contain a lot of strings, maybe some
as barewords, some coderefs, etc. You should manually import strict and
warnings B<before> importing MooX::Press to ensure all of that is covered
by strictures.

=head2 Why all the factory stuff?

Factories are big and cool and they put lots of smoke into our atmosphere.

Also, if you do something like:

  use constant APP => 'MyGarden';
  use MooX::Press (
    prefix => APP,
    role  => [
      'LeafGrower' => {
        has => [ '@leafs' => sub { [] } ],
        can => {
          'grow_leaf' => sub {
            my $self = shift;
            my $leaf = $self->FACTORY->new_leaf;
            push @{ $self->leafs }, $leaf;
            return $leaf;
          },
        },
      },
    ],
    class => [
      'Leaf',
      'Tree'  => { with => ['LeafGrower'] },
    ],
  );
  
  my $tree = APP->new_tree;
  my $leaf = $tree->grow_leaf;

And you will notice that the string "MyGarden" doesn't appear anywhere in
the definitions for any of the classes and roles. The prefix could be
changed to something else entirely and all the classes and roles, all the
methods within them, would continue to work.

Whole collections of classes and roles now have portable namespaces. The same
classes and roles could be used with different prefixes in different scripts.
You could load two different versions of your API in the same script with
different prefixes. The possibilities are interesting.

=head2 Why doesn't C<< $object->isa("Leaf") >> work?

In the previous question, C<< $object->isa("Leaf") >> won't work to check
if an object is a Leaf. This is because the full name of the class is
"MyGarden::Leaf".

You can of course check C<< $object->isa("MyGarden::Leaf") >> but this
means you're starting to hard-code class names and prefixes again, which
is one of the things MooX::Press aims to reduce.

The "correct" way to check something is a leaf is:

  use MyGarden::Types qw( is_Leaf );
  
  if ( is_Leaf($object) ) {
    ...;
  }

Or if you really want to use C<isa>:

  use MyGarden::Types qw( Leaf );
  
  if ( $object->isa(Leaf->class) ) {
    ...;
  }

However, the type library is only available I<after> you've used MooX::Press.
This can make it tricky to refer to types within your methods.

  use constant APP => 'MyGarden';
  use MooX::Press (
    prefix => APP,
    class => [
      'Leaf',
      'Tree'  => {
        can => {
          'add_leaf' => sub {
            my ($self, $leaf) = @_;
            
            # How to check is_Leaf() here?
            # It's kind of tricky!
            
            my $t = $self->FACTORY->type_library->get_type('Leaf');
            if ($t->check($leaf)) {
              ...;
            }
          },
        },
      },
    ],
  );

As of version 0.019, MooX::Press has method signatures, so you're less
likely to need to check types within your methods; you can just do it in
the signature. This won't cover every case you need to check types, but
it will cover the common ones.

  use constant APP => 'MyGarden';
  use MooX::Press (
    prefix => APP,
    class => [
      'Leaf',
      'Tree'  => {
        can => {
          'add_leaf' => {
            signature => ['Leaf'],
            code      => sub {
              my ($self, $leaf) = @_;
              ...;
            },
          },
        },
      },
    ],
  );

This also makes your code more declarative and less imperative, and that
is a Good Thing, design-wise.

=head2 The plural of "leaf" is "leaves", right?

Yeah, but that sounds like something is leaving.

=head2 How do generators work?

A class generator is like a class of classes.

A role generator is like a class of roles.

  use MooX::Press (
    prefix => 'MyApp',
    class  => [
      'Animal' => {
        has => ['$name'],
      },
    ],
    class_generator => [
      'Species' => sub {
        my ($gen, $binomial) = @_;
        return {
          extends  => ['Animal'],
          constant => { binomial => $binomial },
        };
      },
    ],
  );

This generates MyApp::Animal as a class, as you might expect, but also
creates a class generator called MyApp::Species.

MyApp::Species is not itself a class but it can make classes. Calling
either C<< MyApp::Species->generate_package >> or
C<< MyApp->generate_species >> will compile a new class
and return the class name as a string.

  my $Human = MyApp->generate_species('Homo sapiens');
  my $Dog   = MyApp->generate_species('Canis familiaris');
  
  my $alice = $Human->new(name => 'Alice');
  say $alice->name;      # Alice
  say $alice->binomial;  # Homo sapiens
  
  my $fido  = $Dog->new(name => 'Fido');
  $fido->isa($Dog);               # true
  $fido->isa($Human);             # false
  $fido->isa('MyApp::Animal');    # true
  $fido->isa('MyApp::Species');   # false!!!
  
  use Types::Standard -types;
  use MyApp::Types -types;
  
  is_ClassName($fido)             # false
  is_Object($fido)                # true
  is_Animal($fido);               # true
  is_SpeciesInstance($fido);      # true
  is_SpeciesClass($fido);         # false
  is_ClassName($Dog)              # true
  is_Object($Dog)                 # false
  is_Animal($Dog);                # false
  is_SpeciesInstance($Dog);       # false
  is_SpeciesClass($Dog);          # true

Note that there is no B<Species> type created, but instead a pair of types
is created: B<SpeciesClass> and B<SpeciesInstance>.

It is also possible to inherit from generated classes.

  use MooX::Press (
    prefix => 'MyApp',
    class  => [
      'Animal' => {
        has => ['$name'],
      },
      'Dog' => {
        extends => [ 'Species' => ['Canis familiaris'] ]
      },
    ],
    class_generator => [
      'Species' => sub {
        my ($gen, $binomial) = @_;
        return {
          extends  => ['Animal'],
          constant => { binomial => $binomial },
        };
      },
    ],
  );
  
  my $fido = MyApp->new_dog(name => 'Fido');

The inheritance heirarchy for C<< $fido >> is something like:

  Moo::Object
  ->  MyApp::Animal
    ->  MyApp::Species::__GEN000001__
      ->  MyApp::Dog

Note that MyApp::Species itself isn't in that heirarchy!

Generated roles work pretty much the same, but C<role_generator> instead
of C<class_generator>, C<does> instead of C<isa>, and C<with> instead of
C<extends>.

No type constraints are automatically created for generated roles.

=head2 Are you insane?

Quite possibly.

=head1 BUGS

Please report any bugs to
L<http://rt.cpan.org/Dist/Display.html?Queue=MooX-Press>.

=head1 SEE ALSO

L<Moo>, L<MooX::Struct>, L<Types::Standard>.

L<portable::loader>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2019-2020 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

