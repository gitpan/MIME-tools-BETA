package MIME::Parser::RedoUU;


=head1 NAME

MIME::Parser::RedoUU - a Redoer which sniffs out uuencoded data.


=head1 DESCRIPTION

Look for embedded "begin" lines in a text/plain, like this:

    Content-type: text/plain
    
    begin 644 Hello.gif
    M1TE&.#=A$P`3`*$``/___P```("`@,#`P"P`````$P`3```"1X2/F<'MSTQ0
    M%(@)YMB\;W%)@$<.(*:5W2F2@<=F8]>LH4P[7)P.T&NZI7Z,(&JF^@B121Y3
    4Y4SNEJ"J]8JZ:JTH(K$"/A0``#L`
    `
    end

Whenever we are confronted with a message whose effective 
content-type is "text/plain", we scan the decoded body to see 
if it contains uuencoded data (generally given away by a "begin XXX" line). 
By default, we scan only the first 24 lines, though you can change
this if you need to.

If it does, we explode the uuencoded message into a multipart, 
where the text before the first "begin XXX" becomes the first part,
and all "begin...end" sections following become the subsequent parts. 
The filename (if given) is accessible through the normal means.

Notice that, since this action is triggered by a "redo", it will
work even if the original uuencoded file has been base64-encoded.
I have no earthly idea if that's a I<good> thing, but it's pretty cool
if you want it to be.  :-)  

Note: I do not schedule the uuencoded portions for re-doing.
I could, but I don't.  

=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use vars qw(@ISA);
use MIME::Parser::Redoer;

@ISA = qw(MIME::Parser::Redoer);

#------------------------------

sub init {
    my ($self) = @_;
    $self->{Horizon} = 24;
}

#------------------------------

=item horizon LINES

I<Instance method.>
Set the number of lines to read while looking for lines like
"begin 644", before giving up.  Negative means no limit.
Default is 24.

=cut

sub horizon {
    my ($self, $h) = @_;
    $self->{Horizon} = $h;
}

#------------------------------

=item redo IN, ENTITY, PARSER

I<Instance method.>
Try to detect and dispatch embedded uuencode as a fake multipart message.
Returns new entity or undef.

=cut

sub redo {
    my ($self, $in, $ent, $parser) = @_;
    my $good;
    local $_;
    $parser->debug("sniffing around for UUENCODE");

    ### Verify that we want to try it:
    unless (($ent->effective_type =~ m{^text/plain\Z}) &&
	    ($ent->head->mime_encoding =~ m{^})) {
	return undef;   ### rule it out immediately
    }

    ### Get some info:
    my $MIME_Entity = $parser->interface('ENTITY_CLASS');

    ### Heuristic:
    $in->seek(0,0);
    my $line = 1;
    while (defined($_ = $in->getline)) {
	last if ($good = /^begin [0-7]{3}/);
	last if ($self->{Horizon} >= 0) and ($line > $self->{Horizon});
    } continue { ++$line }
    if (!$good) {
	$parser->debug("did not find 'begin xxx' line".
		       (($self->{Horizon} < 0) 
			? " anywhere in the message" 
			: " in the first $self->{Horizon} lines"));
	return undef;
    }
    $parser->debug("found 'begin xxx' on line $line ...");

    ### New entity:
    my $top_ent = $ent->dup;      ### no data yet
    $top_ent->make_multipart; 
    my @parts;

    ### Made the first cut; on to the real stuff:
    $in->seek(0,0);
    my $decoder = MIME::Decoder->new('x-uuencode');
    my $pre;
    while (1) {
	my @bin_data;

	### Try next part:
	my $out = IO::ScalarArray->new(\@bin_data);
	eval { $decoder->decode($in, $out) }; last if $@;
	my $preamble = $decoder->last_preamble;
	my $filename = $decoder->last_filename;
	my $mode     = $decoder->last_mode;

	### Get probable type (KLUDGE):
	my $type = 'application/octet-stream';
	my ($ext) = $filename =~ /\.(\w+)\Z/; $ext = lc($ext || '');
	if ($ext =~ /^(gif|jpe?g|xbm|xpm|png)\Z/) { $type = "image/$1" }
	
	### If we got our first preamble, create the text portion:
	if (@$preamble and 
	    (grep /\S/, @$preamble) and
	    !@parts) {
	    my $txt_ent = $MIME_Entity->build(Type     => "text/plain",
					      Encoding => "7bit",
					      Data     => "");
	    $txt_ent->bodyhandle($parser->new_body_for($txt_ent->head));
	    my $io = $txt_ent->bodyhandle->open("w");
	    $io->print(@$preamble);
	    $io->close;
	    push @parts, $txt_ent;
	}
	
	### Create the attachment:
	### We use the x-unix-mode convention from "dtmail 1.2.1 SunOS 5.6".
	if (1) {
	    my $bin_ent = $MIME_Entity->build(Type     => $type,
					      Encoding => "base64",
					      Filename => $filename, 
					      Data     => "");
	    $bin_ent->head->mime_attr('Content-type.x-unix-mode' => "0$mode");
	    $bin_ent->bodyhandle($parser->new_body_for($bin_ent->head));
	    $bin_ent->bodyhandle->binmode(1);
	    my $io = $bin_ent->bodyhandle->open("w");
	    $io->print(@bin_data);
	    $io->close;
	    push @parts, $bin_ent;
	}
    }

    ### Did we get anything?
    @parts or return undef;

    ### Set the parts and a nice preamble:
    $top_ent->parts(\@parts);
    $top_ent->preamble
	(["The following is a multipart MIME message which was extracted\n",
	  "from a uuencoded message.\n"]);
    $top_ent;
}


1;
