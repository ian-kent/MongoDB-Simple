package MTest;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;

database 'mtest';
collection 'items';

string 'name'        => {
    changed => sub {
        my ($self, $value) = @_;
        eval {
            my $obj = new MTest::Duplicate(client => $self->client);
            $obj->load($self->doc->{_id});
            $obj->name($value);
            $obj->save;
        };
    }
};
date 'created'       => undef;
boolean 'available'  => undef;
object 'attr'        => undef;
array 'tags'         => undef;
object 'metadata'    => { type => 'MTest::Meta' };
array 'labels'       => { type => 'MTest::Label' };
array 'multi'        => { types => [ 'MTest::Meta', 'MTest::Label' ] };

package MTest::Meta;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;

parent type => 'MTest', key => 'metadata';

matches sub {
    my ($doc) = @_;
    my %keys = map { $_ => 1 } keys %$doc;
    return 1 if scalar keys %keys == 1 && $keys{type};
    return 0;
};

string 'type'  => undef;

package MTest::Label;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;

parent type => 'MTest', key => 'labels';

matches sub {
    my ($doc) = @_;
    my %keys = map { $_ => 1 } keys %$doc;
    return 1 if (scalar keys %keys == 1) && $keys{text};
    return 0;
};

string 'text'  => undef;

package MTest::Duplicate;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;
use Data::Dumper;

database 'mtest';
collection 'itemlist';

dbref 'item_id';
string 'name';

locator sub {
    my ($self, $id) = @_;

    return {
        'item_id' => $self->item_id || {
            '$ref' => 'items',
            '$id' => $id
        }
    };
};

1;
