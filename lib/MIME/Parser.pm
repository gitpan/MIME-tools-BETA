package MIME::Parser;


=head1 NAME

MIME::Parser - experimental class for parsing MIME streams


=head1 SYNOPSIS

Before reading further, you should see L<MIME::Tools> to make sure that 
you understand where this module fits into the grand scheme of things.
Go on, do it now.  I'll wait.

Ready?  Ok...

=head2 Basic usage examples

    ### Create a new parser object:
    my $parser = new MIME::Parser;
     
    ### Tell it where to put things:
    $parser->output_under("/tmp");
     
    ### Parse an input filehandle:
    $entity = $parser->parse(\*STDIN);
    
    ### Congratulations: you now have a (possibly multipart) MIME entity!
    $entity->dump_skeleton;          # for debugging 


=head2 Examples of input

    ### Parse from filehandles:
    $entity = $parser->parse(\*STDIN);
    $entity = $parser->parse(IO::File->new("some command|");
	  
    ### Parse from any object that supports getline() and read():
    $entity = $parser->parse($myHandle);
     
    ### Parse an in-core MIME message:
    $entity = $parser->parse_data($message);
         
    ### Parse an MIME message in a file:
    $entity = $parser->parse_open("/some/file.msg");
    
    ### Parse an MIME message out of a pipeline:
    $entity = $parser->parse_open("gunzip - < file.msg.gz |");
      
    ### Parse already-split input (as "deliver" would give it to you):
    $entity = $parser->parse_two("msg.head", "msg.body");


=head2 Examples of output control

    ### Keep parsed message bodies in core (default outputs to disk):
    $parser->output_to_core(1);
     
    ### Output each message body to a one-per-message directory:
    $parser->output_under("/tmp");
     
    ### Output each message body to the same directory:
    $parser->output_dir("/tmp");
    
    ### Change how nameless message-component files are named:
    $parser->output_prefix("msg");


=head2 Examples of error recovery

    ### Normal mechanism:
    eval { $entity = $parser->parse(\*STDIN) };
    if ($@) {
	$results  = $parser->results;
	$decapitated = $parser->last_head;  ### get last top-level head
    }
    
    ### Ultra-tolerant mechanism:
    $parser->ignore_errors(1);
    $entity = eval { $parser->parse(\*STDIN) };
    $error = ($@ || $parser->last_error);
    
    ### Cleanup all files created by the parse:
    eval { $entity = $parser->parse(\*STDIN) };
    ...
    $parser->filer->purge;


=head2 Examples of parser options

    ### Automatically attempt to RFC-1522-decode the MIME headers?
    $parser->decode_headers(1);             ### default is false
          
    ### Parse contained "message/rfc822" objects as nested MIME streams?
    $parser->extract_nested_messages(0);    ### default is true 
     
    ### Look for uuencode in "text" messages, and extract it?
    $parser->extract_uuencode(1);           ### default is false
          
    ### Should we forgive normally-fatal errors?
    $parser->ignore_errors(0);              ### default is true 


=head2 Miscellaneous examples

    ### Convert a Mail::Internet object to a MIME::Entity:
    @lines = (@{$mail->header}, "\n", @{$mail->body});
    $entity = $parser->parse_data(\@lines);



=head1 DESCRIPTION

You can inherit from this class to create your own subclasses 
that parse MIME streams into MIME::Entity objects.


=head1 PUBLIC INTERFACE

=cut

#------------------------------

# We require the new FileHandle methods, and a non-buggy version
# of FileHandle->new_tmpfile:
require 5.004; 

### Pragmas:
use strict;
use vars (qw($VERSION $CAT $CRLF $BM));

### Built-in modules:
use FileHandle ();
use IO::Wrap;
use IO::Scalar       1.117;
use IO::ScalarArray  1.114;
use IO::Lines        1.108;
use IO::File;
use IO::InnerFile;
use File::Spec;
use File::Path;
use Config qw(%Config);
use Carp;

### Kit modules:
use MIME::Tools qw(:config :utils :msgtypes usage tmpopen );
use MIME::Head;
use MIME::Body;
use MIME::Entity;
use MIME::Decoder;
use MIME::Parser::Reader;
use MIME::Parser::Filer;
use MIME::Parser::Results;
use MIME::Parser::RedoUU;

#============================================================
#
# A special kind of inner file that we can virtually print to.
#
package MIME::Parser::InnerFile;

use vars qw(@ISA);
@ISA = qw(IO::InnerFile);

sub print {
    shift->add_length(length(join('', @_)));
}

sub PRINT  {
    shift->{LG} += length(join('', @_));
}

#============================================================

package MIME::Parser;


#------------------------------
#
# Globals
#
#------------------------------

### The package version, both in 1.23 style *and* usable by MakeMaker:
$VERSION = substr q$Revision: 5.505 $, 10;

### How to catenate:
$CAT = '/bin/cat';

### The CRLF sequence:
$CRLF = "\015\012";

### Who am I?
my $ME = 'MIME::Parser';



#------------------------------------------------------------

=head2 Construction

=over 4

=cut

#------------------------------

=item new ARGS...

I<Class method.>
Create a new parser object.  
Once you do this, you can then set up various parameters
before doing the actual parsing.  For example:

    my $parser = new MIME::Parser;
    $parser->output_dir("/tmp");
    $parser->output_prefix("msg1");
    my $entity = $parser->parse(\*STDIN);

Any arguments are passed into C<init()>.
Don't override this in your subclasses; override init() instead.

=cut

sub new {
    my $self = bless {}, shift;
    $self->init(@_);
}

#------------------------------

=item init ARGS...

I<Instance method.>
Initiallize a new MIME::Parser object.  
This is automatically sent to a new object; you may want to override it.
If you override this, be sure to invoke the inherited method.

=cut

sub init {
    my $self = shift;

    ### Core attributes:
    $self->{MP5_DecodeHeaders}   = 0;
    $self->{MP5_Interface}       = {};
    $self->{MP5_ExtractNested}   = 'NEST';   
    $self->{MP5_ExtractEncoded}  = 1;
    $self->{MP5_Tmp}             = undef;
    $self->{MP5_TmpRecycling}    = 1;
    $self->{MP5_TmpToCore}       = 0;
    $self->{MP5_IgnoreErrors}    = 1;
    $self->{MP5_UseInnerFiles}   = 0;
    $self->{MP5_Redoers}         = [];

    ### Default setup:
    $self->interface(ENTITY_CLASS => 'MIME::Entity');
    $self->interface(HEAD_CLASS   => 'MIME::Head');
    $self->output_dir(".");

    $self; 
}

#------------------------------

=item init_parse

I<Instance method.>
Invoked automatically whenever one of the top-level parse() methods
is called, to reset the parser to a "ready" state.

=cut

sub init_parse {
    my $self = shift;

    ### Clear the results:
    $self->{MP5_Results} = new MIME::Parser::Results;

    #### Clear the filer:
    $self->{MP5_Filer}->results($self->{MP5_Results});
    $self->{MP5_Filer}->init_parse();
    $self->{MP5_Filer}->purgeable([]);   ### just to be safe
    
    ### Clear the TO-DO list:
    $self->{MP5_ToDo} = [];
    1;
}

=back

=cut





#------------------------------------------------------------

=head2 Altering how messages are parsed

=over 4

=cut

#------------------------------

=item decode_headers [YESNO]

I<Instance method.>
Controls whether the parser will attempt to decode all the MIME headers
(as per RFC-1522) the moment it sees them.  B<This is not advisable
for two very important reasons:>

=over

=item *

B<It screws up the extraction of information from MIME fields.>
If you fully decode the headers into bytes, you can inadvertently 
transform a parseable MIME header like this:

    Content-type: text/plain; filename="=?ISO-8859-1?Q?Hi=22Ho?=" 

into unparseable gobbledygook; in this case:

    Content-type: text/plain; filename="Hi"Ho"

=item *

B<It is information-lossy.>  An encoded string which contains
both Latin-1 and Cyrillic characters will be turned into a binary
mishmosh which simply can't be rendered.

=back

B<History.>
This method was once the only out-of-the-box way to deal with attachments
whose filenames had non-ASCII characters.  However, since MIME-tools 5.4xx 
this is no longer necessary.

B<Parameters.>
If YESNO is true, decoding is done.  However, you will get a warning 
unless you use one of the special "true" values:

   "I_NEED_TO_FIX_THIS"
          Just shut up and do it.  Not recommended.
          Provided only for those who need to keep old scripts functioning.

   "I_KNOW_WHAT_I_AM_DOING"
          Just shut up and do it.  Not recommended.
          Provided for those who REALLY know what they are doing.

If YESNO is false (the default), no attempt at decoding will be done.
With no argument, just returns the current setting.
B<Remember:> you can always decode the headers I<after> the parsing
has completed (see L<MIME::Head::decode()|MIME::Head/decode>), or
decode the words on demand (see L<MIME::Words>).

=cut

sub decode_headers {
    my ($self, $yesno) = @_;
    if (@_ > 1) {
	$self->{MP5_DecodeHeaders} = $yesno;
	if ($yesno) {
	    if (($yesno eq "I_KNOW_WHAT_I_AM_DOING") ||
		($yesno eq "I_NEED_TO_FIX_THIS")) {
		### ok
	    }
	    else {
		$self->whine("as of 5.4xx, decode_headers() should NOT be ".
			     "set true... if you are doing this to make sure ".
			     "that non-ASCII filenames are translated, ".
			     "that's now done automatically; for all else, ".
			     "use MIME::Words.");
	    }
	}
    }
    $self->{MP5_DecodeHeaders};
}


#------------------------------

=item extract_encoded_messages OPTION

I<Instance method.>
Some MIME messages will contain a part of type C<message/*>
or C<multipart/*> which has been erroneously encoded (the RFCs
state that the only valid Content-transfer-encodings for these
types are 7bit, 8bit, and binary).

If you set this option true (the default is false), then
the parser will B<re-parse> encoded bodies after decoding them.  
For example:

    1. We encounter a base64-encoded multipart/mixed, so we...
       a. Decode the body as though it were an ordinary message part,
       b. Open a temporary handle on the decoded body,
       c. Parse the decoded body like an ordinary message,
    2. And finally, continue with the rest of the original message.

B<This is an expensive operation,> and you should really
only use it if you need the maximum amount of tolerance 
or if you understand the risks:

=over 4

=item *

With this option set true, the same data may be 
parsed multiple times.  For example, a base64-encoded
multipart may itself contain base64-encoded multiparts
which need to be reparsed, and so on, so the same patch
of data may be parsed and re-parsed many times.

=item *

The current implementation does a breadth-first parsing/decoding,
which means that arbitrarily-nested messages don't consume 
arbitrary resources.

=back

=cut

sub extract_encoded_messages {
    my ($self, $option) = @_;
    $self->{MP5_ExtractEncoded} = $option;
}



#------------------------------

=item extract_nested_messages OPTION

I<Instance method.>
Some MIME messages will contain a part of type C<message/rfc822>:
literally, the text of an embedded mail/news/whatever message.  
This option controls whether (and how) we parse that embedded message.

If the OPTION is false, we treat such a message just as if it were a 
C<text/plain> document, without attempting to decode its contents.  

If the OPTION is true (the default), the body of the C<message/rfc822> 
part is parsed by this parser, creating an entity object.  
What happens then is determined by the actual OPTION:

=over 4

=item NEST or 1

The default setting.
The contained message becomes the sole "part" of the C<message/rfc822> 
entity (as if the containing message were a special kind of
"multipart" message).  
You can recover the sub-entity by invoking the L<parts()|MIME::Entity/parts> 
method on the C<message/rfc822> entity.

=item REPLACE

The contained message replaces the C<message/rfc822> entity, as though
the C<message/rfc822> "container" never existed.  

B<Warning:> notice that, with this option, all the header information 
in the C<message/rfc822> header is lost.  This might seriously bother
you if you're dealing with a top-level message, and you've just lost
the sender's address and the subject line.  C<:-/>.

=back

I<Thanks to Andreas Koenig for suggesting this method.>

=cut

sub extract_nested_messages {
    my ($self, $option) = @_;
    $self->{MP5_ExtractNested} = $option if (@_ > 1);
    $self->{MP5_ExtractNested};
}

sub parse_nested_messages {
    usage "parse_nested_messages() is now extract_nested_messages()";
    shift->extract_nested_messages(@_);
}

#------------------------------

=item extract_uuencode [YESNO]

I<Instance method, convenience.>
Setting this true is equivalent to:

    $self->redoer('extract_uuencode', new MIME::Parser::RedoUU);

If set true (which is the default as of 5.5x), then whenever we 
are confronted with a message whose effective content-type is
"text/plain" and whose encoding is 7bit/8bit/binary, we scan the 
encoded body to see if it contains uuencoded data (generally given 
away by a "begin XXX" line). 

If it does, we explode the uuencoded message into a multipart, 
where the text before the first "begin XXX" becomes the first part,
and all "begin...end" sections following become the subsequent parts. 
The filename (if given) is accessible through the normal means.

=cut

sub extract_uuencode {
    my ($self, $yesno) = @_;    
    my $redoer = ($yesno ? new MIME::Parser::RedoUU : undef);
    $self->redoer('extract_uuencode', $redoer);
}

#------------------------------

=item ignore_errors [YESNO]

I<Instance method.>
Controls whether the parser will attempt to ignore normally-fatal
errors, treating them as warnings and continuing with the parse.

If YESNO is true (the default), many syntax errors are tolerated.
If YESNO is false, fatal errors throw exceptions.
With no argument, just returns the current setting.

=cut

sub ignore_errors {
    my ($self, $yesno) = @_;
    $self->{MP5_IgnoreErrors} = $yesno if (@_ > 1);
    $self->{MP5_IgnoreErrors};
}

#------------------------------

=item redoer NAME, REDOER

I<Instance method.>
Add/remove a "redoer". See L<MIME::Parser::Redoer>.
Also see L<extract_uuencode()|/extract_uuencode>.

A REDOER of undef removes it.
Redoers are triggered in the order they are added.

=cut

sub redoer {
    my ($self, $name, $redoer) = @_;

    ### Remove existing, if any:
    $self->{MP5_Redoers} = [grep { $_->[0] ne $name } @{$self->{MP5_Redoers}}];

    ### Add new to the end:
    push @{$self->{MP5_Redoers}}, [$name, $redoer]  if $redoer;
}






#------------------------------
#
# MESSAGES...
#

#------------------------------
#
# debug MESSAGE...
#
sub debug {
    my $self = shift;
    if (my $r = $self->{MP5_Results}) {
	unshift @_, $r->indent;
	$r->msg($M_DEBUG, @_);
    }
    &MIME::Tools::debug(@_); 
}

#------------------------------
#
# whine PROBLEM...
#
sub whine {
    my $self = shift;
    if (my $r = $self->{MP5_Results}) {
	unshift @_, $r->indent;
	$r->msg($M_WARNING, @_);
    }
    &MIME::Tools::whine(@_);
}

#------------------------------
#
# error PROBLEM...
#
# Possibly-forgivable parse error occurred.
# Raises a fatal exception unless we are ignoring errors.
#
sub error {
    my $self = shift;
    if (my $r = $self->{MP5_Results}) {
	unshift @_, $r->indent;
	$r->msg($M_ERROR, @_); 
    }
    &MIME::Tools::error(@_); 
    $self->{MP5_IgnoreErrors} ? return undef : die @_;
}




#------------------------------
#
# PARSING...
#

#------------------------------
#
# process_preamble IN, READER, ENTITY
#
# I<Instance method.>
# Dispose of a multipart message's preamble.
#
sub process_preamble {
    my ($self, $in, $rdr, $ent) = @_;

    ### Sanity:
    ($rdr->depth > 0) or die "$ME: internal logic error";
    
    ### Parse preamble:
    my @saved;
    $rdr->read_lines($in, \@saved);
    $ent->preamble(\@saved);
    1;
}

#------------------------------
#
# process_epilogue IN, READER, ENTITY
#
# I<Instance method.>
# Dispose of a multipart message's epilogue.
#
sub process_epilogue {
    my ($self, $in, $rdr, $ent) = @_;
    $self->debug("process_epilogue");

    ### Parse epilogue:
    my @saved;
    $rdr->read_lines($in, \@saved);
    $ent->epilogue(\@saved);
    1;
}

#------------------------------
#
# process_to_bound IN, READER, OUT
#
# I<Instance method.>
# Dispose of the next chunk into the given output stream OUT.
# 
sub process_to_bound {
    my ($self, $in, $rdr, $out) = @_;        

    ### Parse:
    my $bm = benchmark {
	$rdr->read_chunk($in, $out);
    };
    $self->debug("t bound: $bm");
    1;
}

#------------------------------
#
# process_header IN, READER
#
# I<Instance method.>
# Process and return the next header.
# Fatal exception on failure.
#
sub process_header {
    my ($self, $in, $rdr) = @_;
    $self->debug("process_header");

    ### Parse and save the (possibly empty) header, up to and including the
    ###    blank line that terminates it:
    my $head = $self->interface('HEAD_CLASS')->new;

    ### Read the lines of the header.
    ### We localize IO inside here, so that we can support the IO:: interface
    my @headlines;
    my $hdr_rdr = $rdr->spawn;
    $hdr_rdr->add_terminator("");
    $hdr_rdr->add_terminator("\r");           ### sigh
    $hdr_rdr->read_lines($in, \@headlines);
    foreach (@headlines) { s/[\r\n]+\Z/\n/ }  ### fold

    ### How did we do?
    ($hdr_rdr->eos_type eq 'DONE') or
	$self->error("unexpected end of header\n");

    ### Cleanup bogus header lines.
    ###    Some folks like to parse mailboxes, so the header will start
    ###    with "From " or ">From ".  Tolerate this by removing both kinds
    ###    of lines silently (can't we use Mail::Header for this, and try
    ###    and keep the envelope?).  Ditto for POP.
    while (@headlines) {
	if    ($headlines[0] =~ /^>?From /) {    ### mailbox
	    $self->whine("skipping bogus mailbox 'From ' line");
	    shift @headlines;
	}
	elsif ($headlines[0] =~ /^\+OK/) {       ### POP3 status line
	    $self->whine("skipping bogus POP3 '+OK' line");
	    shift @headlines;
	}
	else { last }
    }

    ### Extract the header (note that zero-size headers are admissible!):
    $head->extract(\@headlines);
    @headlines and 
	$self->error("couldn't parse head; error near:\n",@headlines);

    ### If desired, auto-decode the header as per RFC-1522.  
    ###    This shouldn't affect non-encoded headers; however, it will decode
    ###    headers with international characters.  WARNING: currently, the
    ###    character-set information is LOST after decoding.
    $head->decode($self->{MP5_DecodeHeaders}) if $self->{MP5_DecodeHeaders};

    ### If this is the top-level head, save it:
    $self->results->top_head($head) if !$self->results->top_head;

    return $head;
}

#------------------------------
#
# process_multipart IN, READER, ENTITY
#
# I<Instance method.>
# Process the multipart body, and return the state.
# Fatal exception on failure.
# Invoked by process_part().
#
# This method assumes that the IN data is non-encoded,
# regardless of the content-transfer-encoding.  This is
# to support graceful re-parsing.
#
sub process_multipart {
    my ($self, $in, $rdr, $ent) = @_;
    my $head = $ent->head;
    
    $self->debug("process_multipart...");

    ### Get actual type and subtype from the header:
    my ($type, $subtype) = (split('/', $head->mime_type), "");
    
    ### If this was a type "multipart/digest", then the RFCs say we
    ### should default the parts to have type "message/rfc822".
    ### Thanks to Carsten Heyl for suggesting this...
    my $retype = (($subtype eq 'digest') ? 'message/rfc822' : '');

    ### Get the boundaries for the parts:
    my $bound = $head->multipart_boundary;
    if (!defined($bound) || ($bound =~ /[\r\n]/)) {
	$self->error("multipart boundary is missing, or contains CR or LF\n");
	$ent->effective_type("application/x-unparseable-multipart");
	return $self->process_singlepart($in, $rdr, $ent);
    }
    my $part_rdr = $rdr->spawn->add_boundary($bound);

    ### Prepare to parse:
    my $eos_type;
    my $more_parts;

    ### Parse preamble...
    $self->process_preamble($in, $part_rdr, $ent);

    ### ...and look at how we finished up:
    $eos_type = $part_rdr->eos_type;
    if    ($eos_type eq 'DELIM'){ $more_parts = 1 }
    elsif ($eos_type eq 'CLOSE'){ $self->whine("empty multipart message\n");
				  $more_parts = 0; }
    else                        { $self->error("unexpected end of preamble\n");
				  return 1; }

    ### Parse parts: 
    my $partno = 0;
    my $part;
    while ($more_parts) {
	++$partno;
	$self->debug("parsing part $partno...");
	
	### Parse the next part, and add it to the entity...
	my $part = $self->process_part($in, $part_rdr, Retype=>$retype);
	$ent->add_part($part);

	### ...and look at how we finished up:
	$eos_type = $part_rdr->eos_type;
	if    ($eos_type eq 'DELIM') { $more_parts = 1 }
	elsif ($eos_type eq 'CLOSE') { $more_parts = 0; }
	else                         { $self->error("unexpected end of parts ".
						    "before epilogue\n");
				       return 1; }
    }
    
    ### Parse epilogue... 
    ###    (note that we use the *parent's* reader here, which does not
    ###     know about the boundaries in this multipart!)
    $self->process_epilogue($in, $rdr, $ent);

    ### ...and there's no need to look at how we finished up!
    1;
}

#------------------------------
#
# process_singlepart IN, READER, ENTITY
#
# I<Instance method.>
# Process the singlepart body.  Returns true.
# Fatal exception on failure.
# Invoked by process_part().
#
sub process_singlepart {
    my ($self, $in, $rdr, $ent) = @_;
    my $head    = $ent->head;

    $self->debug("process_singlepart...");

    ### Obtain a filehandle for reading the encoded information:
    ###    We have two different approaches, based on whether or not we 
    ###    have to contend with boundaries.
    my $ENCODED;             ### handle
    my $can_shortcut = !$rdr->has_bounds;
    if ($can_shortcut) {
	$self->debug("taking shortcut");

	$ENCODED = $in;
	$rdr->eos('EOF');   ### be sure to bogus-up the reader state to EOF:
    }
    else {

	### Can we read real fast?
	if ($self->{MP5_UseInnerFiles} && 
	    $in->can('seek') && $in->can('tell')) {
	    $self->debug("using inner file");
	    $ENCODED = MIME::Parser::InnerFile->new($in, $in->tell, 0);
	}
	else {
	    $self->debug("using temp file");
	    $ENCODED = $self->new_tmpfile($self->{Tmp});
	    $self->{Tmp} = $ENCODED if $self->{TmpRecycle};
	}

	### Read encoded body until boundary (or EOF)...
	$self->process_to_bound($in, $rdr, $ENCODED);

	### ...and look at how we finished up.
	###     If we have bounds, we want DELIM or CLOSE.
	###     Otherwise, we want EOF (and that's all we'd get, anyway!).
	if ($rdr->has_bounds) {
	    ($rdr->eos_type =~ /^(DELIM|CLOSE)$/) or
		$self->error("part did not end with expected boundary\n");
	}

	### Flush and rewind encoded buffer, so we can read it:
	$ENCODED->flush;
	$ENCODED->seek(0, 0);
    }

    ### Get a content-decoder to decode this part's encoding:
    my $encoding = $head->mime_encoding;
    my $decoder = new MIME::Decoder $encoding;
    if (!$decoder) {
	$self->whine("Unsupported encoding '$encoding': using 'binary'... \n".
		     "The entity will have an effective MIME type of \n".
		     "application/octet-stream.");  ### as per RFC-2045
	$ent->effective_type('application/octet-stream');
	$decoder = new MIME::Decoder 'binary';
    }

    ### Open a new bodyhandle for outputting the data:
    my $body = $self->new_body_for($head) || die "$ME: no body\n"; # gotta die
    $body->binmode(1);  ### unless textual_type($ent->effective_type);

    ### Decode and save the body (using the decoder):
    my $DECODED = $body->open("w") || die "$ME: body not opened: $!\n"; 
    my $bm = benchmark {
	eval { $decoder->decode($ENCODED, $DECODED); }; 
	$@ and $self->error($@);
    };
    $self->debug("t decode: $bm");
    $DECODED->close;
    
    ### Success!  Remember where we put stuff:
    $ent->bodyhandle($body);


    ### The decoded singlepart may actually contain embedded containers
    ### of a non-standard format; e.g., a text/plain which actually
    ### contains uuencoded data.
    $self->enqueue_task("redo singlepart", sub {
	$self->debug(@{$self->{MP5_Redoers}} . " redoers installed");
	foreach my $r (@{$self->{MP5_Redoers}}) {
	    my ($name, $redoer) = @$r;
	    $self->debug("trying redoer: $name");

	    ### Try out this redoer:
	    $self->results->level(+1);
	    my $new = eval { $redoer->redo($body->open("r"), $ent, $self); };
	    $self->results->level(-1);
	    if ($@) {         ### failed hard
		next;
	    }
	    elsif ($new) {    ### it worked!
		$self->debug("matched redoer: $name");
		%$ent = %$new; 
		last;
	    }	    
	}
    });

    ### Done!
    1;
}

#------------------------------
#
# process_message IN, READER, ENTITY
#
# I<Instance method.>
# Process the singlepart body, and return true.
# Fatal exception on failure.
# Invoked by process_part().
#
# This method assumes that the IN data is non-encoded,
# regardless of the content-transfer-encoding.  This is
# to support graceful re-parsing.
#
sub process_message {
    my ($self, $in, $rdr, $ent) = @_;
    my $head = $ent->head;

    $self->debug("process_message");

    ### Parse the message:
    my $msg = $self->process_part($in, $rdr);

    ### How to handle nested messages?
    if ($self->extract_nested_messages eq 'REPLACE') {
	%$ent = %$msg;          ### shallow replace
	%$msg = ();
    }
    else {                      ### "NEST" or generic 1:
	$ent->bodyhandle(undef);
	$ent->add_part($msg);
    }
    1;
}

#------------------------------
#
# process_part IN, READER, [OPTSHASH...]
#
# I<Instance method.>
# The real back-end engine.
# See the documentation up top for the overview of the algorithm.
# The OPTSHASH can contain:
#
#    Retype => retype this part to the given content-type
#
# Return the entity.
# Fatal exception on failure.
#
sub process_part {
    my ($self, $in, $rdr, %p) = @_;

    $rdr ||= MIME::Parser::Reader->new;
    #debug "process_part";
    $self->results->level(+1);

    ### Create a new entity:
    my $ent = $self->interface('ENTITY_CLASS')->new;

    ### Parse and add the header:
    my $head = $self->process_header($in, $rdr);
    $ent->head($head);   

    ### Tweak the content-type based on context from our parent...
    ### For example, multipart/digest messages default to type message/rfc822:
    $head->mime_type($p{Retype}) if $p{Retype};
    
    ### Unencoded bodies may be processed according to MIME type;
    ### Encoded bodies must first be processed as singleparts:
    my $classify = $self->classify($head);
    if ($head->mime_encoding =~ /^(7bit|8bit|binary)$/) { 

	### Classify... how should we parse it?
	if    ($classify eq 'multipart') {
	    $self->process_multipart($in, $rdr, $ent);
	}
	elsif ($classify eq 'message') {
	    $self->process_message($in, $rdr, $ent);
	}
	elsif ($classify eq 'singlepart') {                     
	    $self->process_singlepart($in, $rdr, $ent);
	}
	else {
	    croak "internal error: unknown classification '$classify'";
	}
    }
    else {                         ### encoded body:

	### First, decode:
	$self->process_singlepart($in, $rdr, $ent);

	### Should we (and can we) re-parse this encoded part?
	if (($classify ne 'singlepart') and $self->{MP5_ExtractEncoded}) {
	    $self->enqueue_task("reparse encoded container", sub {

		### Set up input, etc.
		my $re_in = $ent->bodyhandle->open('r');
		my $re_rdr = MIME::Parser::Reader->new;
		
		### Handle by classification:
		if    ($classify eq 'multipart') {
		    $self->process_multipart($re_in, $re_rdr, $ent);
		}
		elsif ($classify eq 'message') {
		    $self->process_message($re_in, $re_rdr, $ent);
		}
		else {
		    croak "internal error: bad classification '$classify'";
		}

		### Cleanup:
		$re_in->close;
	    });
	}
    }

    ### Done (we hope!):
    $self->results->level(-1);
    return $ent;
}

#------------------------------
# classify HEAD
#------------------------------
# Instance method, private.
# Classify the [unencoded] contents of a message as one of these:
#
#    "multipart"   the unencoded body is a MIME multipart body
#    "message"     the unencoded body is a re-parseable "message/*" document
#    "singlepart"  the unencoded body is anything else (e.g., "text/html")
#
# Notice that we only classify as "message" if we are allowed to
# extract nested messages; otherwise, it's just a [flat] singlepart.
#
sub classify {
    my ($self, $head) = @_;

    ### Get the MIME type and subtype:
    my ($type, $subtype) = (split('/', $head->mime_type), '');
    my $fulltype = "$type/$subtype";
    $self->debug("classify: type = $type, subtype = $subtype");

    ### Handle, according to the MIME type:
    if ($type eq 'multipart') {
	return 'multipart';
    }
    elsif ($self->extract_nested_messages) {
	if (($fulltype eq "message/rfc822") or
	    ($fulltype eq "application/x-pkcs7-mime")) { 
	    return 'message';
	}
	else {
	    return 'singlepart';
	}
    }
    else {                     
	return 'singlepart';
    }
}

#------------------------------
# enqueue_task NAME, SUBREF
#------------------------------
# Enqueue a task to perform.
#
sub enqueue_task {
    my ($self, $name, $subref) = @_;
    $self->debug("ENQUEUE TASK: $name");
    push @{$self->{ToDo}}, [$name, $subref];
}

#------------------------------
# dequeue_task
#------------------------------
# Dequeue and perform the next task;
# Returns true if there were tasks, false if no tasks remain.
#
sub dequeue_task {
    my ($self) = @_;
    my ($name, $subref) = @{ shift(@{$self->{ToDo}}) || [] };
    $subref or return undef;
    $self->debug("RUN TASK: $name");
    $self->results->level(+1);
    &$subref;
    $self->results->level(-1);
    1;
}



=back

=head2 Parsing an input source

=over 4

=cut

#------------------------------

=item parse_data DATA

I<Instance method.>
Parse a MIME message that's already in core.  
You may supply the DATA in any of a number of ways...

=over 4

=item *

B<A scalar> which holds the message.

=item *

B<A ref to a scalar> which holds the message.  This is an efficiency hack.

=item *

B<A ref to an array of scalars.>  They are treated as a stream
which (conceptually) consists of simply concatenating the scalars.

=back

Returns the parsed MIME::Entity on success.  
Throws exception on failure.

=cut

sub parse_data {
    my ($self, $data) = @_;

    ### Get data as a scalar:    
    my $io;
  switch: while(1) {
      (!ref($data)) and do {
	  $io = new IO::Scalar \$data; last switch;
      };
      (ref($data) eq 'SCALAR') and do {
	  $io = new IO::Scalar $data; last switch;
      };
      (ref($data) eq 'ARRAY') and do {
	  $io = new IO::ScalarArray $data; last switch;
      };
      croak "parse_data: wrong argument ref type: ", ref($data);
  }
    
    ### Parse!
    return $self->parse($io);
}

#------------------------------

=item parse INSTREAM

I<Instance method.>
Takes a MIME-stream and splits it into its component entities.

The INSTREAM can be given as a readable FileHandle, an IO::File,
a globref filehandle (like C<\*STDIN>),
or as I<any> blessed object conforming to the IO:: interface
(which minimally implements getline() and read()).

Returns the parsed MIME::Entity on success.  
Throws exception on failure.

=cut

sub parse {
    my $self = shift;
    my $in = wraphandle(shift);    ### coerce old-style filehandles to objects
    my $entity;
    local $/ = "\n";    ### just to be safe

    my $bm = benchmark {

	### Init:
	$self->init_parse;
	
	### Create initial task:
	$self->enqueue_task("initial processing", sub {
	    ($entity) = $self->process_part($in, undef); 	    
	});
	
	### Dispatch tasks until done:
	1 while ($self->dequeue_task);	    
    };
    $self->debug("t parse: $bm");

    $entity;
}

### Backcompat:
sub read { 
    shift->parse(@_); 
}
sub parse_FH { 
    shift->parse(@_); 
}

#------------------------------

=item parse_open EXPR

I<Instance method.>
Convenience front-end onto C<parse()>.
Simply give this method any expression that may be sent as the second
argument to open() to open a filehandle for reading. 

Returns the parsed MIME::Entity on success.  
Throws exception on failure.

=cut

sub parse_open {
    my ($self, $expr) = @_;
    my $ent;

    my $io = IO::File->new($expr) or die "$ME: couldn't open $expr: $!\n";
    $ent = $self->parse($io);
    $io->close;
    $ent;
}

### Backcompat:
sub parse_in { 
    usage "parse_in() is now parse_open()"; 
    shift->parse_open(@_); 
}

#------------------------------

=item parse_two HEADFILE, BODYFILE

I<Instance method.>
Convenience front-end onto C<parse_open()>, intended for programs 
running under mail-handlers like B<deliver>, which splits the incoming
mail message into a header file and a body file.
Simply give this method the paths to the respective files.  

B<Warning:> it is assumed that, once the files are cat'ed together,
there will be a blank line separating the head part and the body part.

B<Warning:> new implementation slurps files into line array
for portability, instead of using 'cat'.  May be an issue if 
your messages are large.

Returns the parsed MIME::Entity on success.  
Throws exception on failure.

=cut

sub parse_two {
    my ($self, $headfile, $bodyfile) = @_;
    my @lines;
    foreach ($headfile, $bodyfile) {
	open IN, "<$_" or die "$ME: open $_: $!";
	push @lines, <IN>;
	close IN;
    }
    return $self->parse_data(\@lines);
}

=back

=cut




#------------------------------------------------------------

=head2 Specifying output destination

B<Warning:> in 5.212 and before, this was done by methods 
of MIME::Parser.  However, since many users have requested 
fine-tuned control over how this is done, the logic has been split
off from the parser into its own class, MIME::Parser::Filer
Every MIME::Parser maintains an instance of a MIME::Parser::Filer 
subclass to manage disk output (see L<MIME::Parser::Filer> for details.)

The benefit to this is that the MIME::Parser code won't be 
confounded with a lot of garbage related to disk output.
The drawback is that the way you override the default behavior 
will change.

For now, all the normal public-interface methods are still provided, 
but many are only stubs which create or delegate to the underlying 
MIME::Parser::Filer object.

=over 4

=cut

#------------------------------

=item filer [FILER]

I<Instance method.>
Get/set the FILER object used to manage the output of files to disk.
This will be some subclass of L<MIME::Parser::Filer|MIME::Parser::Filer>.

=cut

sub filer {
    my ($self, $filer) = @_;
    if (@_ > 1) {
	$self->{MP5_Filer} = $filer;
	$filer->results($self->results);  ### but we still need in init_parse
    }
    $self->{MP5_Filer};
}

#------------------------------

=item output_dir DIRECTORY

I<Instance method.>
Causes messages to be filed directly into the given DIRECTORY.  
It does this by setting the underlying L<filer()|/filer> to 
a new instance of MIME::Parser::FileInto, and passing the arguments 
into that class' new() method.

B<Note:> Since this method replaces the underlying
filer, you must invoke it I<before> doing changing any attributes
of the filer, like the output prefix; otherwise those changes
will be lost.

=cut

sub output_dir {
    my ($self, @init) = @_;
    if (@_ > 1) { 
	$self->filer(MIME::Parser::FileInto->new(@init));
    }
    else { 
	&MIME::Tools::whine("0-arg form of output_dir is deprecated.");
	return $self->filer->output_dir;
    }
}

#------------------------------

=item output_under BASEDIR, OPTS...

I<Instance method.>
Causes messages to be filed directly into subdirectories of the given
BASEDIR, one subdirectory per message.  It does this by setting the 
underlying L<filer()|/filer> to a new instance of MIME::Parser::FileUnder,
and passing the arguments into that class' new() method.

B<Note:> Since this method replaces the underlying
filer, you must invoke it I<before> doing changing any attributes
of the filer, like the output prefix; otherwise those changes
will be lost.

=cut

sub output_under {
    my ($self, @init) = @_;
    if (@_ > 1) { 
	$self->filer(MIME::Parser::FileUnder->new(@init));
    }
    else { 
	&MIME::Tools::whine("0-arg form of output_under is deprecated.");
	return $self->filer->output_dir;
    }
}

#------------------------------

=item output_path HEAD

I<Instance method, DEPRECATED.>
Given a MIME head for a file to be extracted, come up with a good
output pathname for the extracted file.
Identical to the preferred form:
 
     $parser->filer->output_path(...args...);

We just delegate this to the underlying L<filer()|/filer> object.

=cut

sub output_path {
    my $self = shift;
    ### We use it, so don't warn!
    ### &MIME::Tools::whine("output_path deprecated in MIME::Parser");
    $self->filer->output_path(@_);
}

#------------------------------

=item output_prefix [PREFIX]

I<Instance method, DEPRECATED.>
Get/set the short string that all filenames for extracted body-parts 
will begin with (assuming that there is no better "recommended filename").  
Identical to the preferred form:
 
     $parser->filer->output_prefix(...args...);

We just delegate this to the underlying L<filer()|/filer> object.

=cut

sub output_prefix {
    my $self = shift;
    &MIME::Tools::whine("output_prefix deprecated in MIME::Parser");
    $self->filer->output_prefix(@_);
}

#------------------------------

=item evil_filename NAME

I<Instance method, DEPRECATED.>
Identical to the preferred form:
 
     $parser->filer->evil_filename(...args...);

We just delegate this to the underlying L<filer()|/filer> object.

=cut

sub evil_filename {
    my $self = shift;
    &MIME::Tools::whine("evil_filename deprecated in MIME::Parser");
    $self->filer->evil_filename(@_);
}

#------------------------------

=item output_to_core YESNO

I<Instance method.>
Normally, instances of this class output all their decoded body
data to disk files (via MIME::Body::File).  However, you can change 
this behaviour by invoking this method before parsing:

If YESNO is false (the default), then all body data goes 
to disk files.

If YESNO is true, then all body data goes to in-core data structures
This is a little risky (what if someone emails you an MPEG or a tar 
file, hmmm?) but people seem to want this bit of noose-shaped rope,
so I'm providing it.  
Note that setting this attribute true I<does not> mean that parser-internal
temporary files are avoided!  Use L<tmp_to_core()|/tmp_to_core> for that.

With no argument, returns the current setting as a boolean.

=cut

sub output_to_core {
    my ($self, $yesno) = @_;
    if (@_ > 1) {
	$yesno = 0 if ($yesno and $yesno eq 'NONE');
	$self->{MP5_FilerToCore} = $yesno;
    }
    $self->{MP5_FilerToCore};
}

#------------------------------

=item tmp_recycling [YESNO]

I<Instance method.>
Normally, tmpfiles are created when needed during parsing, and
destroyed automatically when they go out of scope.  But for efficiency,
you might prefer for your parser to attempt to rewind and reuse the 
same file until the parser itself is destroyed.

If YESNO is true (the default), we allow recycling; 
tmpfiles persist until the parser itself is destroyed.
If YESNO is false, we do not allow recycling; 
tmpfiles persist only as long as they are needed during the parse.
With no argument, just returns the current setting.

=cut

sub tmp_recycling {
    my ($self, $yesno) = @_;
    $self->{MP5_TmpRecycling} = $yesno if (@_ > 1);
    $self->{MP5_TmpRecycling};
}

#------------------------------

=item tmp_to_core [YESNO]

I<Instance method.>
Should L<new_tmpfile()|/new_tmpfile> create real temp files, or 
use fake in-core ones?  Normally we allow the creation of temporary 
disk files, since this allows us to handle huge attachments even when 
core is limited.

If YESNO is true, we implement new_tmpfile() via in-core handles.
If YESNO is false (the default), we use real tmpfiles.
With no argument, just returns the current setting.

=cut

sub tmp_to_core {
    my ($self, $yesno) = @_;
    $self->{MP5_TmpToCore} = $yesno if (@_ > 1);
    $self->{MP5_TmpToCore};
}

#------------------------------

=item use_inner_files [YESNO]

I<Instance method.>
If you are parsing from a handle which supports seek() and tell(), 
then we can avoid tmpfiles completely by using IO::InnerFile, if so 
desired: basically, we simulate a temporary file via pointers
to virtual start- and end-positions in the input stream.

If YESNO is false (the default), then we will not use IO::InnerFile.
If YESNO is true, we use IO::InnerFile if we can. 
With no argument, just returns the current setting.

B<Note:> inner files are slower than I<real> tmpfiles,
but possibly faster than I<in-core> tmpfiles... so your choice for
this option will probably depend on your choice for 
L<tmp_to_core()|/tmp_to_core> and the kind of input streams you are 
parsing.

=cut

sub use_inner_files {
    my ($self, $yesno) = @_;
    $self->{MP5_UseInnerFiles} = $yesno if (@_ > 1);
    $self->{MP5_UseInnerFiles};
}

=back

=cut


#------------------------------------------------------------

=head2 Specifying classes to be instantiated

=over 4

=cut

#------------------------------

=item interface ROLE,[VALUE]

I<Instance method.>
During parsing, the parser normally creates instances of certain classes, 
like MIME::Entity.  However, you may want to create a parser subclass
that uses your own experimental head, entity, etc. classes (for example,
your "head" class may provide some additional MIME-field-oriented methods).

If so, then this is the method that your subclass should invoke during 
init.  Use it like this:

    package MyParser;
    @ISA = qw(MIME::Parser);
    ...
    sub init {
	my $self = shift;
	$self->SUPER::init(@_);        ### do my parent's init
        $self->interface(ENTITY_CLASS => 'MIME::MyEntity');
	$self->interface(HEAD_CLASS   => 'MIME::MyHead');
	$self;                         ### return
    }

With no VALUE, returns the VALUE currently associated with that ROLE.

=cut

sub interface {
    my ($self, $role, $value) = @_;
    $self->{MP5_Interface}{$role} = $value if (defined($value));
    $self->{MP5_Interface}{$role};
}

#------------------------------

=item new_body_for HEAD

I<Instance method.>
Based on the HEAD of a part we are parsing, return a new
body object (any desirable subclass of MIME::Body) for
receiving that part's data.

If you set the C<output_to_core> option to false before parsing
(the default), then we call C<output_path()> and create a
new MIME::Body::File on that filename.

If you set the C<output_to_core> option to true before parsing, 
then you get a MIME::Body::InCore instead.

If you want the parser to do something else entirely, you can
override this method in a subclass.

=cut

sub new_body_for {
    my ($self, $head) = @_;

    if ($self->output_to_core) {
	$self->debug("outputting body to core");
	return (new MIME::Body::InCore);
    }
    else {
	my $outpath = $self->output_path($head);
	$self->debug("outputting body to disk file: $outpath");
	$self->filer->purgeable($outpath);        ### we plan to use it
	return (new MIME::Body::File $outpath);
    }
}

#------------------------------

=item new_tmpfile [RECYCLE]

I<Instance method.>
Return an IO handle to be used to hold temporary data during a parse.
The default uses the standard IO::File->new_tmpfile() method unless
L<tmp_to_core()|/tmp_to_core> dictates otherwise, but you can override this.  
You shouldn't need to.

If you do override this, make certain that the object you return is 
set for binmode(), and is able to handle the following methods:

    read(BUF, NBYTES)
    getline()
    getlines()
    print(@ARGS)
    flush() 
    seek(0, 0)

Fatal exception if the stream could not be established.

If RECYCLE is given, it is an object returned by a previous invocation 
of this method; to recycle it, this method must effectively rewind and 
truncate it, and return the same object.  If you don't want to support
recycling, just ignore it and always return a new object.

=cut

sub new_tmpfile {
    my ($self, $recycle) = @_;

    my $io;
    if ($self->{MP5_TmpToCore}) {         ### Use an in-core tmpfile (slow)
	$io = IO::ScalarArray->new;
    }
    else {                                ### Use a real tmpfile (fast)
	                                       ### Recycle?
	if ($self->{TmpRecycling} &&                 ### we're recycling
	    $recycle &&                              ### something to recycle
	    $Config{'truncate'} && $io->can('seek')  ### recycling will work
	    ){                 	
	    $self->debug("recycling tmpfile: $io");
	    $io->seek(0, 0);
	    truncate($io, 0);
	}
	else {                                 ### Return a new one:
	    $io = tmpopen() || die "$ME: can't open tmpfile: $!\n";
	    binmode($io);
	}
    }
    return $io;
}

=back

=cut






#------------------------------------------------------------

=head2 Parse results and error recovery

=over 4

=cut

#------------------------------

=item last_error

I<Instance method.>
Return the error (if any) that we ignored in the last parse.

=cut

sub last_error {
    join '', shift->results->errors;
}


#------------------------------

=item last_head

I<Instance method.>
Return the top-level MIME header of the last stream we attempted to parse.
This is useful for replying to people who sent us bad MIME messages.

    ### Parse an input stream:
    eval { $entity = $parser->parse(\*STDIN) };
    if (!$entity) {    ### parse failed!
	my $decapitated = $parser->last_head;  
	...
    }

=cut

sub last_head {
    shift->results->top_head;
}

#------------------------------

=item results

I<Instance method.>
Return an object containing lots of info from the last entity parsed.
This will be an instance of class 
L<MIME::Parser::Results|MIME::Parser::Results>.

=cut

sub results {
    shift->{MP5_Results};
}


=back

=cut


#------------------------------
1;
__END__


=head1 OPTIMIZING YOUR PARSER


=head2 Maximizing speed

Optimum input mechanisms:

    parse()                    YES (if you give it a globref or a 
				    subclass of IO::File)
    parse_open()               YES
    parse_data()               NO  (see below)
    parse_two()                NO  (see below)

Optimum settings:

    decode_headers()           *** (no real difference; 0 is slightly faster)
    extract_nested_messages()  0   (may be slightly faster, but in 
                                    general you want it set to 1)
    output_to_core()           0   (will be MUCH faster)
    tmp_recycling()            1?  (probably, but should be investigated)
    tmp_to_core()              0   (will be MUCH faster)
    use_inner_files()          0   (if tmp_to_core() is 0; 
				    use 1 otherwise)

B<File I/O is much faster than in-core I/O.>
Although it I<seems> like slurping a message into core and
processing it in-core should be faster... it isn't.
Reason: Perl's filehandle-based I/O translates directly into 
native operating-system calls, whereas the in-core I/O is 
implemented in Perl.

B<Inner files are slower than real tmpfiles, but faster than in-core ones.>
If speed is your concern, that's why
you should set use_inner_files(true) if you set tmp_to_core(true):
so that we can bypass the slow in-core tmpfiles if the input stream 
permits.

B<Native I/O is much faster than object-oriented I/O.>
It's much faster to use E<lt>$fooE<gt> than $foo-E<gt>getline.
For backwards compatibilty, this module must continue to use 
object-oriented I/O in most places, but if you use L<parse()|/parse> 
with a "real" filehandle (string, globref, or subclass of IO::File)
then MIME::Parser is able to perform some crucial optimizations.  

B<The parse_two() call is very inefficient.>
Currently this is just a front-end onto parse_data().
If your OS supports it, you're I<far> better off doing something like:

    $parser->parse_open("/bin/cat msg.head msg.body |");




=head2 Minimizing memory

Optimum input mechanisms:

    parse()                    YES
    parse_open()               YES
    parse_data()               NO  (in-core I/O will burn core)
    parse_two()                NO  (in-core I/O will burn core)

Optimum settings:

    decode_headers()           *** (no real difference)
    extract_nested_messages()  *** (no real difference)
    output_to_core()           0   (will use MUCH less memory)
    tmp_recycling()            0?  (promotes faster GC if 
                                    tmp_to_core is 1)
    tmp_to_core()              0   (will use MUCH less memory)
    use_inner_files()          *** (no real difference, but set it to 1 
				    if you *must* have tmp_to_core set to 1,
				    so that you avoid in-core tmpfiles)


=head2 Maximizing tolerance of bad MIME

Optimum input mechanisms:

    parse()                    *** (doesn't matter)
    parse_open()               *** (doesn't matter)
    parse_data()               *** (doesn't matter)
    parse_two()                *** (doesn't matter)

Optimum settings:

    decode_headers()           0   (sidesteps problem of bad hdr encodings)
    extract_nested_messages()  0   (sidesteps problems of bad nested messages,
                                    but often you want it set to 1 anyway).
    output_to_core()           *** (doesn't matter)
    tmp_recycling()            *** (doesn't matter)
    tmp_to_core()              *** (doesn't matter)
    use_inner_files()          *** (doesn't matter)


=head2 Avoiding disk-based temporary files

Optimum input mechanisms:

    parse()                    YES (if you give it a seekable handle)
    parse_open()               YES (becomes a seekable handle) 
    parse_data()               NO  (unless you set tmp_to_core(1))
    parse_two()                NO  (unless you set tmp_to_core(1))

Optimum settings:

    decode_headers()           *** (doesn't matter)
    extract_nested_messages()  *** (doesn't matter)
    output_to_core()           *** (doesn't matter)
    tmp_recycling              1   (restricts created files to 1 per parser)
    tmp_to_core()              1 
    use_inner_files()          1

B<If we can use them, inner files avoid most tmpfiles.>
If you parse from a seekable-and-tellable filehandle, then the internal 
process_to_bound() doesn't need to extract each part into a temporary 
buffer; it can use IO::InnerFile (B<warning:> this will slow down 
the parsing of messages with large attachments).

B<You can veto tmpfiles entirely.>
If you might not be parsing from a seekable-and-tellable filehandle,
you can set L<tmp_to_core()|/tmp_to_core> true: this will always 
use in-core I/O for the buffering (B<warning:> this will slow down 
the parsing of messages with large attachments).  

B<Final resort.>
You can always override L<new_tmpfile()|/new_tmpfile> in a subclass.







=head1 WARNINGS

=over 4

=item Multipart messages are always read line-by-line 

Multipart document parts are read line-by-line, so that the
encapsulation boundaries may easily be detected.  However, bad MIME
composition agents (for example, naive CGI scripts) might return
multipart documents where the parts are, say, unencoded bitmap
files... and, consequently, where such "lines" might be 
veeeeeeeeery long indeed.

A better solution for this case would be to set up some form of 
state machine for input processing.  This will be left for future versions.


=item Multipart parts read into temp files before decoding

In my original implementation, the MIME::Decoder classes had to be aware
of encapsulation boundaries in multipart MIME documents.
While this decode-while-parsing approach obviated the need for 
temporary files, it resulted in inflexible and complex decoder
implementations.

The revised implementation uses a temporary file (a la C<tmpfile()>)
during parsing to hold the I<encoded> portion of the current MIME 
document or part.  This file is deleted automatically after the
current part is decoded and the data is written to the "body stream"
object; you'll never see it, and should never need to worry about it.

Some folks have asked for the ability to bypass this temp-file
mechanism, I suppose because they assume it would slow down their application.
I considered accomodating this wish, but the temp-file
approach solves a lot of thorny problems in parsing, and it also
protects against hidden bugs in user applications (what if you've
directed the encoded part into a scalar, and someone unexpectedly
sends you a 6 MB tar file?).  Finally, I'm just not conviced that 
the temp-file use adds significant overhead.


=item Fuzzing of CRLF and newline on input

RFC-1521 dictates that MIME streams have lines terminated by CRLF
(C<"\r\n">).  However, it is extremely likely that folks will want to 
parse MIME streams where each line ends in the local newline 
character C<"\n"> instead. 

An attempt has been made to allow the parser to handle both CRLF 
and newline-terminated input.


=item Fuzzing of CRLF and newline on output

The C<"7bit"> and C<"8bit"> decoders will decode both
a C<"\n"> and a C<"\r\n"> end-of-line sequence into a C<"\n">.

The C<"binary"> decoder (default if no encoding specified) 
still outputs stuff verbatim... so a MIME message with CRLFs 
and no explicit encoding will be output as a text file 
that, on many systems, will have an annoying ^M at the end of
each line... I<but this is as it should be>.


=item Inability to handle multipart boundaries that contain newlines

First, let's get something straight: I<this is an evil, EVIL practice,>
and is incompatible with RFC-1521... hence, it's not valid MIME.

If your mailer creates multipart boundary strings that contain
newlines I<when they appear in the message body,> give it two weeks notice 
and find another one.  If your mail robot receives MIME mail like this, 
regard it as syntactically incorrect MIME, which it is.

Why do I say that?  Well, in RFC-1521, the syntax of a boundary is 
given quite clearly:

      boundary := 0*69<bchars> bcharsnospace
        
      bchars := bcharsnospace / " "
      
      bcharsnospace :=    DIGIT / ALPHA / "'" / "(" / ")" / "+" /"_"
                   / "," / "-" / "." / "/" / ":" / "=" / "?"

All of which means that a valid boundary string I<cannot> have 
newlines in it, and any newlines in such a string in the message header
are expected to be solely the result of I<folding> the string (i.e.,
inserting to-be-removed newlines for readability and line-shortening 
I<only>).

Yet, there is at least one brain-damaged user agent out there 
that composes mail like this:

      MIME-Version: 1.0
      Content-type: multipart/mixed; boundary="----ABC-
       123----"
      Subject: Hi... I'm a dork!
      
      This is a multipart MIME message (yeah, right...)
      
      ----ABC-
       123----
      
      Hi there! 

We have I<got> to discourage practices like this (and the recent file
upload idiocy where binary files that are part of a multipart MIME
message aren't base64-encoded) if we want MIME to stay relatively 
simple, and MIME parsers to be relatively robust. 

I<Thanks to Andreas Koenig for bringing a baaaaaaaaad user agent to
my attention.>


=back



=head1 AUTHOR

Eryq (F<eryq@zeegee.com>), ZeeGee Software Inc (F<http://www.zeegee.com>).

All rights reserved.  This program is free software; you can redistribute 
it and/or modify it under the same terms as Perl itself.



=head1 VERSION

$Revision: 5.505 $ $Date: 2001/09/14 06:38:11 $

=cut




