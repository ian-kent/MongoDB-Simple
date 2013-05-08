package MTest;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;

database 'mtest';
collection 'items';

string 'name'        => undef;
date 'created'       => undef;
boolean 'available'  => undef;
object 'attr'        => undef;
array 'tags'         => undef;
object 'metadata'    => { type => 'MTest::Meta' };
array 'labels'       => { type => 'MTest::Label' };

package MTest::Meta;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;

parent type => 'MTest', key => 'metadata';

string 'type'  => undef;

package MTest::Label;

use Mojo::Base 'MongoDB::Simple';
use MongoDB::Simple;

parent type => 'MTest', key => 'labels';

string 'text'  => undef;

1;
