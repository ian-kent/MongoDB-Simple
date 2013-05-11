package MongoDB::Simple;

use strict;
use warnings;
our $VERSION = '0.005';

use Exporter;
our @EXPORT = qw/ collection string date array object parent dbref boolean oid database locator matches /;

use MongoDB;
use MongoDB::Simple::ArrayType;

use Switch;
use DateTime;
use DateTime::Format::W3CDTF;
use Data::Dumper;

our %metadata = (); # internal metadata cache used for all packages

{
    # Setup some MongoDB magic
    #
    # Lets us cast MongoDB results into classes
    #     my $obj = db->coll->find_one({criteria})->as('ClassName');
    #     my $obj = $cursor->next->as('ClassName');

    no strict 'refs';
    no warnings 'redefine';

    my $mongodb_find_one = \&{'MongoDB::Collection::find_one'};
    *{'MongoDB::Simple::Collection::find_one::Result::as'} = sub {
        my ($self, $as) = @_;
        return $as->new(doc => $self);
    };

    *{'MongoDB::Collection::find_one'} = sub {
        return mongodb_blessed_result(&$mongodb_find_one(@_));
    };
    my $mongodb_cursor_next = \&{'MongoDB::Cursor::next'};
    *{'MongoDB::Cursor::next'} = sub {
        return mongodb_blessed_result(&$mongodb_cursor_next);
    };

    sub mongodb_blessed_result {
        my ($result) = @_;
        if($result) {
            return bless $result, 'MongoDB::Simple::Collection::find_one::Result';
        }
        return $result;
    }
}

################################################################################
# Object methods                                                               #
################################################################################

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        'client'        => undef, # stores the client (or can be passed in)
        'db'            => undef, # stores the database (or can be passed in)
        'col'           => undef, # stores the collection (or can be passed in)
        'meta'          => undef, # stores the keyword metadata
        'doc'           => {}, # stores the document
        'changes'       => {}, # stores changes made since load/save
        'callbacks'     => [], # stores callbacks needed for changes
        'parent'        => undef, # stores the parent object
        'objcache'      => {}, # stores created objects
        'arraycache'    => {}, # stores array objects
        'existsInDb'    => 0,
        'debugMode'     => 0,
        'forceUnshiftOperator' => 0, # forces implementation of unshift to work as expected
        'warnOnUnshiftOperator' => 1, # enables a warning when unshift is used against an array without forceUnshiftOperator
        %args
    }, $class;

    # Get metadata for this class
    $self->{meta} = $self->getmeta;

    # Setup db/collection
    if(!$self->{col}) {
        if(!$self->{db}) {
            if($self->{client} && $self->{meta}->{database}) {
                $self->{db} = $self->{client}->get_database($self->{meta}->{database});
            }
        }
        if($self->{client} && $self->{db} && !$self->{col} && $self->{meta}->{collection}) {
            $self->{col} = $self->{db}->get_collection($self->{meta}->{collection});
        }
    }

    # Inject field methods, done first time object of this type is constructed instead of 
    # build time so we can use field names which clash with helper keywords
    {
        no strict 'refs';
        if(!$self->{meta}->{compiled}) {
            for my $field (keys %{$self->{meta}->{fields}}) {
                my $type = $self->{meta}->{fields}->{$field}->{type};
                $self->log("   -- injecting method for field '$field' as type '$type'");
                switch ($type) {
                    case "string" { *{$class.'::'.$field} = sub { return stringAccessor(shift, $field, @_); } }
                    case "date" { *{$class.'::'.$field} = sub { return dateAccessor(shift, $field, @_); } }
                    case "boolean" { *{$class.'::'.$field} = sub { return booleanAccessor(shift, $field, @_); } }
                    case "array" { *{$class.'::'.$field} = sub { return arrayAccessor(shift, $field, @_); } }
                    case "object" { *{$class.'::'.$field} = sub { return objectAccessor(shift, $field, @_); } }
                    case "dbref" { *{$class.'::'.$field} = sub { return dbrefAccessor(shift, $field, @_); } }
                }
                $self->log("-- creating field $field");
            }
            #addmeta('compiled', 1);
            my $pkg = ref $self;
            $metadata{$pkg}{compiled} = 1;
        }
    }

    return $self;
}

sub log {
    my $self = shift;
    print STDERR (@_, "\n") if $self->{debugMode};
}

sub load {
    my $self = shift;

    my $locator = $self->getLocator(@_);
    my $doc = $self->{col}->find_one($locator);

    if(!$doc) {
        die("Failed to load document with locator: " . (Dumper $locator));
    }

    $self->{existsInDb} = 1;
    $self->{doc} = $doc;
    $self->{changes} = {};
    $self->{callbacks} = [];
    $self->{objcache} = {};
    $self->{arraycache} = {};
}

sub getLocator {
    my ($self, $id) = @_;

    # Use a locator{} block if its defined
    if($self->{meta}->{locator}) {
        my $loc = $self->{meta}->{locator};
        return &$loc($self, $id);
    }

    # If id provided isn't a hash, return a mongodb _id matching hash
    if(ref($id) !~ /HASH/) {
        return {
            "_id" => $id // $self->{doc}->{_id}
        };
    };

    # Otherwise return whatever was passed in
    return $id;
}

sub save {
    my ($self) = @_;

    if($self->{existsInDb}) {
        $self->log("Save:: updates:");
        my $updates = $self->getUpdates;
        $self->log(Dumper $updates);
        if(scalar keys %$updates == 0) {
            $self->log("No updates found, not saving");
            return 0;
        }
        $self->log("Exists in db, locator: " . $self->getLocator);
        $self->{col}->update($self->getLocator, $updates);
        $self->{changes} = {};
        for my $cb (@{$self->{callbacks}}) {
            &$cb;
        }
        $self->{callbacks} = [];
    } else {
        my $changes = $self->{changes};
        $self->log("Save:: changes:");
        $self->log(Dumper $changes);
        $self->log("Doesn't exist in db");
        my $id = $self->{col}->insert($changes);
        $self->{existsInDb} = 1;
        $self->{changes} = {};
        $self->{callbacks} = [];
        $self->log(Dumper $id);
        return $id;
    }
}

sub hasChanges {
    my ($self) = @_;

    return scalar keys %{$self->{changes}} > 0 ? 1 : 0;
}

sub getUpdates {
    my ($self) = @_;

    $self->log("getUpdates for " . ref($self));
    my %changes = ();

    # Start with anything added to the changes hash
    for my $key (keys %{$self->{changes}}) {
        # Arrays are done below
        next if $self->{meta}->{fields}->{$key}->{type} =~ /array/i;

        $self->log(" - adding change for $key:");
        $self->log(Dumper $self->{changes}->{$key});
        $changes{'$set'}{$key} = $self->{changes}->{$key};
    }

    # Next loop fields looking for objects or arrays
    for my $field (keys %{$self->{meta}->{fields}}) {
        $self->log("checking field $field");
        if($self->{meta}->{fields}->{$field}->{type} =~ /object/i) {
            $self->log(" - field $field is object type");
            my $obj = $self->$field;
            my $chng = ref($obj) && ref($obj) !~ /HASH/ ? $obj->getUpdates : $obj;
            $self->log(Dumper $chng);
            for my $chg (keys %{$chng->{'$set'}}) {
                $changes{'$set'}{"$field.$chg"} = $chng->{'$set'}->{$chg};
            }
        }
        if($self->{meta}->{fields}->{$field}->{type} =~ /array/i) {
            $self->log(" - field $field is array type");
            $self->$field; # triggers array initialisation if it hasn't already happened
            my $arr = $self->{arraycache}->{$field}->{objref};
            my $chng = $arr->{changes};
            $self->log(Dumper $chng);
            my %types = ( 
                '$push' => '$pushAll',
            );
            my $unshift = $chng->{'$unshift'};
            if($self->{forceUnshiftOperator} && $unshift && scalar @$unshift > 0) { 
                # we've used $unshift, which doesn't exist, so just add the entire array again to simulate it
                $self->log(" - unshift found and forceUnshiftOperator set, rewriting array");
                $changes{'$set'}{"$field"} = $self->$field;
            } else {
                $self->log(" - unshift not found or forceUnshiftOperator => 0");
                # handle fields as normal (i.e. using $remove/$push etc)
                for my $type (keys %types) {
                    my $mtype = $types{$type}; 
                    for my $chg (@{$chng->{$type}}) {
                        $changes{$mtype}{$field} = [] if !$changes{$mtype}{"$field"};
                        if($self->{meta}->{fields}->{$field}->{args}->{type} || $self->{meta}->{fields}->{$field}->{args}->{types}) {
                            push @{$changes{$mtype}{"$field"}}, $chg->{doc};
                        } else {
                            push @{$changes{$mtype}{"$field"}}, $chg;
                        }
                    }
                }
            }
        }
    }

    $self->log(Dumper \%changes);
    return \%changes;
}

sub dump {
    my ($self) = @_;

    $self->log("Dumping " . (ref $self));
    for my $field ( keys %{$self->{meta}->{fields}} ) {
        $self->log("    $field => " . $self->$field);
    }
}

################################################################################
# Accessor methods                                                             #
################################################################################

sub lookForCallbacks {
    my ($self, $field, $value) = @_;

    if($self->{meta}->{fields}->{$field}->{args}->{changed}) {
        push $self->{callbacks}, sub {
            my $cb = $self->{meta}->{fields}->{$field}->{args}->{changed};
            &$cb($self, $value);
        };
    }
}
sub defaultAccessor {
    my ($self, $field, $value) = @_;

    if(scalar @_ <= 2) {
        return $self->{changes}->{$field} // $self->{doc}->{$field};
    }

    return if $self->{doc} && $value && $self->{doc}->{$field} && $value eq $self->{doc}->{$field};

    $self->{changes}->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->{doc}->{$field} = $value;

    $self->lookForCallbacks($field, $value);
}

sub stringAccessor {
    return defaultAccessor(@_);
}
sub booleanAccessor {
    return defaultAccessor(@_);
}
sub dateAccessor {
    my ($self, $field, $value) = @_;

    if(scalar @_ <= 2) {
        $value = $self->{changes}->{$field} // $self->{doc}->{$field};
        $value = DateTime::Format::W3CDTF->new->parse_datetime($value) if $value;
        return $value;
    }

    if(ref($value) =~ /DateTime/) {
        $value = DateTime::Format::W3CDTF->new->format_datetime($value);
    }

    return if $self->{doc} && $value && $self->{doc}->{$field} && $value eq $self->{doc}->{$field};

    $self->{changes}->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->{doc}->{$field} = $value;

    $self->lookForCallbacks($field, $value);
}
sub arrayAccessor {
    my ($self, $field, $value) = @_;

    if(scalar @_ <= 2) {
        if($self->{arraycache}->{$field}) {
            return $self->{arraycache}->{$field}->{arrayref};
        }

        my @arr;
        my $docval = $self->{doc}->{$field};
        if($docval) {
            for my $item (@$docval) {
                my $type = $self->{meta}->{fields}->{$field}->{args}->{type};
                my $types = $self->{meta}->{fields}->{$field}->{args}->{types};
                if($type) {
                    push @arr, $type->new(parent => $self, doc => $item);
                } elsif ($types) {
                    my $matched = 0;
                    for my $type (@$types) {
                        if($metadata{$type}->{matches}) {
                            my $matcher = $metadata{$type}->{matches};
                            my $matches = &$matcher($item);
                            if($matches) {
                                push @arr, $type->new(parent => $self, doc => $item);
                                $matched = 1;
                                last;
                            }
                        }
                    }
                    if(!$matched) {
                        die('No type matched current document: ' . Dumper $item);
                    }
                } else {
                    push @arr, $item;
                }
            }
        }
        my $a = tie my @array, 'MongoDB::Simple::ArrayType', parent => $self, field => $field, array => \@arr;
        $self->{arraycache}->{$field} = {
            arrayref => \@array,
            objref => $a
        };

        return \@array;
    }

    return if $self->{doc} && $value && $self->{doc}->{$field} && $value eq $self->{doc}->{$field};

    if(!tied($value)) {
        my @array;
        my $a = tie @array, 'MongoDB::Simple::ArrayType', parent => $self, field => $field;
        $self->{arraycache}->{$field} = {
            arrayref => \@array,
            objref => $a
        };
        push @array, @$value;
        $value = $a->{array};
    }

    $self->{changes}->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->{doc}->{$field} = $value;

    $self->lookForCallbacks($field, $value);
}
sub objectAccessor {
    my ($self, $field, $value) = @_;

    my $type = $self->{meta}->{fields}->{$field}->{args}->{type};
    my $obj;

    if(scalar @_ <= 2) {
        if($type) {
            if($self->{objcache}->{$field}) {
                return $self->{objcache}->{$field};
            }
            if($self->{doc}->{$field}) {
                $obj = $type->new(parent => $self, doc => $self->{doc}->{$field});
                $self->{objcache}->{$field} = $obj;
            }
            return $obj;
        }
        return $self->{doc}->{$field};
    }

    if(ref($value) !~ /^HASH$/) {
        $self->{objcache}->{$field} = $value;
        $value->{parent} = $self;
        $value = $value->{doc};
    }
    return if $self->{doc} && $value && $self->{doc}->{$field} && $value eq $self->{doc}->{$field};

    $self->{changes}->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->{doc}->{$field} = $value;

    $self->lookForCallbacks($field, $value);
} 
sub dbrefAccessor {
    return defaultAccessor(@_);
}

################################################################################
# Static methods                                                               #
################################################################################

sub import {
    my $class = caller;
#    push @{"$class::ISA"}, $_[0];
    $Exporter::ExportLevel = 1;
    Exporter::import(@_);
}

sub addmeta {
    my ($key, $meta) = @_;
    my $pack = caller 1;
    $metadata{$pack}{$key} = $meta;
    #print "addmeta: adding '$key' to $pack\n";
}
sub addfieldmeta {
    my ($field, $meta) = @_;
    my $pack = caller 1;
    $metadata{$pack}{'fields'}{$field} = $meta;
    #print "addfield: adding '$field' to $pack fields\n";
}

sub getmeta {
    my ($self) = @_;
    my $pack = ref $self;
    #print "getmeta: $pack\n";
    return \%{$metadata{$pack}};
}

sub package_start {
    my $class = caller 1;
    #print "-" x 80;
    #print "\n";
    #print "MongoDB:: Package '$class'\n";
}

sub oid {
    my ($id) = @_;
    return new MongoDB::OID(value => $id);
}

################################################################################
# Keywords                                                                     #
################################################################################

sub locator {
    my ($locator) = @_;
    addmeta("locator", $locator);
}

sub matches {
    my ($matches) = @_;
    addmeta("matches", $matches);
}

sub database {
    my ($database) = @_;
    addmeta("database", $database);
    #print STDERR "MongoDB:: database '$database'\n";
}

sub collection {
    my ($collection) = @_;
    package_start;
    addmeta("collection", $collection);
    #print STDERR "MongoDB:: collection '$collection'\n";
}

sub parent {
    my (%hash) = @_;
    package_start;
    addmeta("parent", \%hash);
    #print STDERR "MongoDB:: parent { type => '$hash{type}', key => '$hash{key}' }\n";
}

sub string {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'string', args => $args });
    #print STDERR "MongoDB:: string '$key' => $value\n";
}

sub date {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'date', args => $args });
    #print STDERR "MongoDB:: date '$key' => $value\n";
}

sub dbref {
    my ($key, $args) = @_;
    #print STDERR "MongoDB:: dbref '$key' =>\n";
    addfieldmeta($key, { type => 'dbref', args => $args });
    for my $ref ( keys %$args ) {
        #print STDERR "    - '$ref' => $args->{$ref}\n";
    }
}

sub boolean {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'boolean', args => $args });
    #print STDERR "MongoDB:: boolean '$key' => $value\n";
}

sub array {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'array', args => $args });
    #print STDERR "MongoDB:: array '$key' => { type => '$args->{type}' }\n";
}

sub object {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'object', args => $args });
    #print STDERR "MongoDB:: object '$key' => { type => '$args->{type}' }\n";
}

    my ($self, @args) = @_;

=head1 NAME

MongoDB::Simple

=head1 SYNOPSIS

    package My::Data::Class;
    use base 'MongoDB::Simple';
    use MongoDB::Simple;

    database 'dbname';
    collection 'collname';

    string 'stringfield' => {
        "changed" => sub {
            my ($self, $value) = @_;
            # ... called when changes to 'stringfield' are saved in database
        }
    };
    date 'datefield';
    boolean 'booleanfield';
    object 'objectfield';
    array 'arrayfield';
    object 'typedobject' => { type => 'My::Data::Class::Foo' };
    array 'typedarray' => { type => 'My::Data::Class::Bar' };
    array 'multiarray' => { types => ['My::Data::Class::Foo', 'My::Data::Class::Bar'] };

    package My::Data::Class::Foo;

    parent type => 'My::Data::Class', key => 'typedobject';

    matches sub {
        my ($doc) = @_;
        my %keys = map { $_ => 1 } keys %$doc;
        return 1 if (scalar keys %keys == 1) && $keys{fooname};
        return 0;
    }

    string 'fooname';

    package My::Data::Class::Bar;

    parent type => 'My::Data::Class', key => 'typedarray';

    matches sub {
        my ($doc) = @_;
        my %keys = map { $_ => 1 } keys %$doc;
        return 1 if (scalar keys %keys == 1) && $keys{barname};
        return 0;
    }

    string 'barname';

    package main;

    use MongoDB;
    use DateTime;

    my $mongo = new MongoClient;
    my $cls = new My::Data::Class(client => $mongo);

    $cls->stringfield("Example string");
    $cls->datefield(DateTime->now);
    $cls->booleanfield(true);
    $cls->objectfield({ foo => "bar" });
    push $cls->arrayfield, 'baz';

    $cls->typedobject(new My::Data::Class::Foo);
    $cls->typedobject->fooname('Foo');

    my $bar = new My::Data::Class::Bar;
    $bar->barname('Bar');
    push $cls->typedarray, $bar;

    my $id = $cls->save;

    my $cls2 = new My::Data::Class(client => $mongo);
    $cls2->load($id);

=head1 DESCRIPTION

L<MongoDB::Simple> simplifies mapping of MongoDB documents to Perl objects.

=head1 SEE ALSO

Documentation needs more work - refer to the examples in the t/test.t file.

=head1 AUTHORS

Ian Kent - <iankent@cpan.org> - original author

=head1 COPYRIGHT AND LICENSE

This library is free software under the same terms as perl itself

Copyright (c) 2013 Ian Kent

MongoDB::Simple is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the license for more details.

=cut

1;
