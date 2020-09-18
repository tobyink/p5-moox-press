if ( $] lt '5.010' ) {
	$meta->{prereqs}{runtime}{requires}{'UNIVERSAL::DOES'} = '0.001';
}

if ( eval { require Moose } ) {
	$meta->{prereqs}{runtime}{requires}{'MooseX::NonMoose'} = '0';
}

if ( eval { require Mouse } ) {
	$meta->{prereqs}{runtime}{requires}{'MouseX::NonMoose'} = '0';
}

