package Chart::Clicker::SQL;
use Moose;
use 5.020;
use feature 'signatures', 'postderef';
no warnings 'experimental::signatures';
no warnings 'experimental::postderef';

use Chart::Clicker;
use Chart::Clicker::Data::DataSet;
use Chart::Clicker::Data::Series;
use DBI;

has dsn => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has user => (
    is  => 'ro',
    isa => 'Str',
    default => '',
);

has pass => (
    is  => 'ro',
    isa => 'Str',
    default => '',
);

has dbh => (
    is      => 'ro',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub ($self) {
        DBI->connect(
            $self->dsn,
            $self->user,
            $self->pass,
            {
                RaiseError => 1,
                ReadOnly => 1,
            }
        )
    },
);

sub render($self, $query) {
    my $sth = $self->dbh->prepare($query);
    $sth->execute;
    my $rows = $sth->fetchall_arrayref;

    my @cols = map {
        my $idx = $_;
        [ map { $_->[$idx] } $rows->@* ]
    } 0..($sth->{NUM_OF_FIELDS} - 1);
    my @names = $sth->{NAME_lc}->@*;
    my $xaxis = shift @names;

    my $chart = Chart::Clicker->new;
    $chart->get_context('default')->domain_axis->label($xaxis);

    my $keys = shift @cols;
    for my $col (@cols) {
        my $series = Chart::Clicker::Data::Series->new(
            name   => shift @names,
            keys   => $keys,
            values => $col,
        );
        my $ds = Chart::Clicker::Data::DataSet->new(series => [ $series ]);
        $chart->add_to_datasets($ds);
    }

    return $chart;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
