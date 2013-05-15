package MongoDB::Simple::ArrayType;

use strict;
use warnings;
our $VERSION = '0.005';

use Tie::Array;
our @ISA = ('Tie::Array');

# Copied from Tie::StdArray and modified to use a hash

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        'array' => [],
        'parent' => undef,
        'field' => undef,
        'meta' => undef,
        'doc' => [], # represents the arrayref used by mongodb
        %args
    }, $class;

    $self->{meta} = $self->{parent}->{meta}->{fields}->{$self->{field}};

    return $self;
}

sub TIEARRAY  { 
    my $class = shift;
    return $class->new(@_);
}
sub FETCHSIZE { 
    my ($self) = @_;
    $self->{parent}->log("ArrayType::FETCHSIZE");
    return scalar @{ $self->{array} };
}
sub STORESIZE { 
    my ($self, $size) = @_;
    $self->{parent}->log("ArrayType::STORESIZE size[$size]");
    $#{$self->{array}} = $size-1;
}
sub STORE     { 
    my ($self, $index, $value) = @_;
    $self->{parent}->log("ArrayType::STORE index[$index], value[$value]");
    $self->[$index] = $value; 
}
sub FETCH     { 
    my ($self, $index) = @_;
    $self->{parent}->log("ArrayType::FETCH index[$index]");
    return $self->{array}->[$index];
}
sub CLEAR     { 
    my ($self) = @_;
    $self->{parent}->log("ArrayType::CLEAR");
    $self->{array} = [];
}
sub POP       { 
    my ($self) = @_;
    $self->{parent}->log("ArrayType::POP");

    my $obj = pop(@{$self->{array}});
    pop @{$self->{doc}};
    if($obj) {
        my $value = $obj;
        $value = $obj->{doc} if ref($obj) !~ /^(|HASH)$/;
        $self->{parent}->registerChange($self->{field}, '$pop', $obj);
    }

    return $obj;
}
sub PUSH      { 
    my $self = shift;
    $self->{parent}->log("ArrayType::PUSH field[" . $self->{field} . "]");
    $self->{parent}->log(caller);

    for(my $i = 0; $i < scalar @_; $i++) {
        my $obj = $_[$i];

        if(ref $obj eq 'HASH' && ($self->{meta}->{args}->{type} || $self->{meta}->{args}->{types})) {
            my $type = $self->{meta}->{args}->{type};
            my $types = $self->{meta}->{args}->{types};
            if($types) {
                for my $type (@$types) {
                    last if $type eq ref($obj);
                    if($MongoDB::Simple::metadata{$type}->{matches}) {
                        my $matcher = $MongoDB::Simple::metadata{$type}->{matches};
                        my $matches = &$matcher($obj);
                        if($matches) {
                            $obj = $type->new(parent => $self->{parent}, doc => $obj, field => $self->{field}, index => scalar @{$self->{array}});
                        }
                    }
                }
            } elsif(ref($obj) ne $type && $type) {
                $obj = $type->new(parent => $self->{parent}, doc => $obj, field => $self->{field}, index => scalar @{$self->{array}});
            }
        }

        if(ref $obj) {
            $obj->{parent} = $self->{parent};
            $obj->{field} = $self->{field};
            $obj->{index} = scalar @{$self->{array}};
        }

        my $value = $obj;
        my $class = ref $obj;
        if($class && $class !~ /HASH/) {
            $value = $obj->{doc};
        }

        # TODO only want to store doc/changes if its a change, not a load
        #push @{$self->{parent}->{changes}->{$self->{field}}}, $value;
        #push @{$self->{parent}->{doc}->{$self->{field}}}, $value;
        $self->{parent}->log("ARRAYTYPE push obj " . (ref $obj));
        $self->{parent}->registerChange($self->{field}, '$push', $value);
        push @{$self->{doc}}, $value;

        push @{$self->{array}}, $obj;
    }
}
sub SHIFT     { 
    my ($self) = @_;
    $self->{parent}->log("ArrayType::SHIFT");
    my $obj = shift(@{$self->{array}});
    shift @{$self->{doc}};
    my $value = $obj;
    my $class = ref $obj;
    if($class && $class !~ /HASH/) {
        $value = $obj->{doc};
    }
    $self->{parent}->registerChange($self->{field}, '$shift', $obj);
    return $obj;
}
sub UNSHIFT   { 
    my $self = shift;

    unless($self->{parent}->{forceUnshiftOperator}) {
        # mongodb doesn't provide an $unshift operator
        # we can still get the item onto the array using push
        # but it appears at the end... the alternative is completely
        # rewriting the array in the right order...
        # FIXME consider adding configurable option to force unshift to work
        if($self->{parent}->{warnOnUnshiftOperator}) {
            warn "unshift on MongoDB::Simple::ArrayType behaves like push";
        }
        $self->{parent}->log("ArrayType::UNSHIFT (forceUnshiftOperator => 0)");
        return PUSH($self, @_);
    }

    # forceUnshiftOperator is set, so we'll trick mongodb into performing
    # an unshift by rewriting the entire array

    $self->{parent}->log("ArrayType::UNSHIFT (forceUnshiftOperator => 1)");

    for(my $i = 0; $i < scalar @_; $i++) {
        my $obj = $_[$i];

        if(ref $obj eq 'HASH' && ($self->{meta}->{args}->{type} || $self->{meta}->{args}->{types})) {
            my $type = $self->{meta}->{args}->{type};
            my $types = $self->{meta}->{args}->{types};
            if($types) {
                for my $type (@$types) {
                    last if $type eq ref($obj);
                    if($MongoDB::Simple::metadata{$type}->{matches}) {
                        my $matcher = $MongoDB::Simple::metadata{$type}->{matches};
                        my $matches = &$matcher($obj);
                        if($matches) {
                            $obj = $type->new(parent => $self->{parent}, doc => $obj);
                        }
                    }
                }
            } elsif(ref($obj) ne $type && $type) {
                $obj = $type->new(parent => $self->{parent}, doc => $obj);
            } else {
                $obj->{parent} = $self->{parent};
            }
        }

        my $value = $obj;
        my $class = ref $obj;
        if($class && $class !~ /HASH/) {
            $value = $obj->{doc};
        }

        # TODO only want to store doc/changes if its a change, not a load
        #unshift @{$self->{parent}->{changes}->{$self->{field}}}, $value;
        #push @{$self->{parent}->{doc}->{$self->{field}}}, $value;
        $self->{'$unshift'} = 1;
        $self->{parent}->registerChange($self->{field}, '$unshift', $obj);

        unshift @{$self->{array}}, $obj;
        unshift @{$self->{doc}}, $obj;
    }
}

sub EXISTS    { 
    my ($self, $index) = @_;
    $self->{parent}->log("ArrayType::EXISTS index[$index]");
    return exists $self->{array}->[$index];
}
sub DELETE    { 
    my ($self, $index) = @_;
    $self->{parent}->log("ArrayType::DELETE index[$index]");
    delete $self->{array}->[$index];
}

sub SPLICE
{
 my $ob  = shift;
 my $sz  = $ob->FETCHSIZE;
 my $off = @_ ? shift : 0;
 $off   += $sz if $off < 0;
 my $len = @_ ? shift : $sz-$off;
 return splice(@{$ob->{array}},$off,$len,@_);
}

1;
