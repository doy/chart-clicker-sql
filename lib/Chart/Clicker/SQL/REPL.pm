package Chart::Clicker::SQL::REPL;
use Moose;
use 5.020;
use feature 'signatures', 'postderef';
no warnings 'experimental::signatures';
no warnings 'experimental::postderef';

use Browser::Open;
use File::HomeDir;
use File::Spec;
use File::Temp;
use Module::Runtime;
use Path::Class;
use Term::ReadLine;

use Chart::Clicker::SQL;

has sql => (
    is        => 'rw',
    isa       => 'Chart::Clicker::SQL',
    predicate => 'initialized',
);

has history_file => (
    is      => 'ro',
    isa     => 'Str',
    default => sub {
        my $filename = File::Spec->catfile(
            File::HomeDir->my_data,
            '.ccsql_history'
        );
        file($filename)->touch;
        return $filename;
    },
);

has rl => (
    is      => 'ro',
    isa     => 'Term::ReadLine',
    lazy    => 1,
    default => sub ($self) {
        my $rl = Term::ReadLine->new(__PACKAGE__);
        for my $line (file($self->history_file)->slurp(chomp => 1)) {
            $rl->addhistory($line);
        }
        return $rl;
    },
);

has chart_options => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            width        => 1000,
            height       => 600,
            set_renderer => Chart::Clicker::Renderer::Line->new,
        }
    },
);

has last_query => (
    is        => 'rw',
    isa       => 'Str',
    predicate => 'has_last_query',
);

sub dsn ($self, $dsn) {
    $self->sql(Chart::Clicker::SQL->new(dsn => $dsn));
}

sub select ($self, $query) {
    $query = "select $query";
    $self->last_query($query);
    $self->_draw;
}

sub _draw ($self) {
    if (!$self->initialized) {
        warn "not initialized";
        return;
    }
    if (!$self->has_last_query) {
        warn "no active query";
        return;
    }
    my $chart = $self->sql->render($self->last_query);
    $self->_configure_chart($chart);
    my ($fh, $filename) = File::Temp::tempfile(SUFFIX => '.png', UNLINK => 1);
    $chart->draw;
    $fh->write($chart->rendered_data);
    $fh->flush;
    Browser::Open::open_browser("file://$filename");
}

sub size ($self, $size) {
    my ($width, $height) = split ' ', $size;
    $self->chart_options->{width} = $width;
    $self->chart_options->{height} = $height;
}

sub title ($self, $title) {
    $self->chart_options->{title} = $title;
}

for my $renderer (qw(Line StackedLine Bar StackedBar Area StackedArea Point)) {
    __PACKAGE__->meta->add_method(lc($renderer) => sub ($self, $args) {
        my $renderer_class = "Chart::Clicker::Renderer::$renderer";
        Module::Runtime::require_module($renderer_class);
        $self->chart_options->{set_renderer} = $renderer_class->new;
        $self->_draw;
    })
}

sub _configure_chart ($self, $chart) {
    $chart->get_context('default')->range_axis->tick_division_type("LinearRounded");
    for my $opt (keys $self->chart_options->%*) {
        $chart->$opt($self->chart_options->{$opt})
            if $chart->can($opt);
    }
}

sub run ($self) {
    while (1) {
        if (defined(my $input = $self->rl->readline("> "))) {
            next unless length($input);
            chomp($input);
            last if $input eq 'exit';
            my ($command, $args) = split(' ', $input, 2);
            $self->$command($args);
        }
        else {
            print "\n";
            last;
        }
    }
}

sub DEMOLISH ($self, $igd) {
    $self->rl->WriteHistory($self->history_file);
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
