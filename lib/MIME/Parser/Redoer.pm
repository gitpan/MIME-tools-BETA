package MIME::Parser::Redoer;

=head1 NAME

MIME::Parser::Redoer - auxilliary parser logic to re-parse files

=head1 DESCRIPTION

Sometimes, we might get files which proport to be one format,
but which we'd like to treat as another; e.g.:

    Content-type: text/plain
    
    begin 644 Hello.gif
    M1TE&.#=A$P`3`*$``/___P```("`@,#`P"P`````$P`3```"1X2/F<'MSTQ0
    M%(@)YMB\;W%)@$<.(*:5W2F2@<=F8]>LH4P[7)P.T&NZI7Z,(&JF^@B121Y3
    4Y4SNEJ"J]8JZ:JTH(K$"/A0``#L`
    `
    end

These files may in fact be MIME-encoded themselves, but
users might still want to detect/extract them.  That's what the
re-doer does.  Every decoded file is visited at least once
by every re-doer installed in the parser.  If the re-doer
sees something interesting, it can use the parser to 
tweak the parsed entity.

=head1 PUBLIC INTERFACE

=over 4

=item redo INSTREAM, ENTITY, PARSER

I<Instance method.>
Re-do the given entity.  
Return false if there does not appear to be anything to [re]do.
Return the replacement entity of something was actually done.

=back

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->init;
    $self;
}

sub redo {
    my ($self, $in, $ent, $parser) = @_;
    undef;
}


1;

