package OpenILS::WWW::AutoSuggest;

use strict;
use warnings;

use Apache2::Log;
use Apache2::Const -compile => qw(
    OK HTTP_NOT_ACCEPTABLE HTTP_INTERNAL_SERVER_ERROR :log
);
use XML::LibXML;
use Text::Glob;
use CGI qw(:all -utf8);

use OpenSRF::Utils::JSON;
use OpenILS::Utils::CStoreEditor qw/:funcs/;

# BEGIN package globals

# We'll probably never need this fanciness for autosuggest, but
# you can add handlers for different requested content-types here, and
# you can weight them to control what matches requests for things like
# 'application/*'

my $_output_handler_dispatch = {
    "application/xml" => {
        "prio" => 0,
        "code" => sub {
            my ($r, $data) = @_;
            $r->content_type("application/xml; charset=utf-8");
            print suggestions_to_xml($data);
            return Apache2::Const::OK;
        }
    },
    "application/json" => {
        "prio" => 1,
        "code" => sub {
            my ($r, $data) = @_;
            $r->content_type("application/json; charset=utf-8");
            print suggestions_to_json($data);
            return Apache2::Const::OK;
        }
    }
};

my @_output_handler_types = sort {
    $_output_handler_dispatch->{$a}->{prio} <=>
        $_output_handler_dispatch->{$b}->{prio}
} keys %$_output_handler_dispatch;

# END package globals

# Given a string such as a user might type into a search box, prepare
# it for to_tsquery(). See
# http://www.postgresql.org/docs/9.0/static/textsearch-controls.html
sub prepare_for_tsquery {
    my ($str) = shift;

    $str =~ s/[^\w\s]/ /ig;
    $str .= ":*" unless $str =~ /\s$/;

    return join(" & ", grep(length, split(/\s+/, $str)));
}

# The third argument to our stored procedure, metabib.suggest_browse_entries(),
# is passed through directly to ts_headline() as the 'options' arugment.
sub prepare_headline_opts {
    my ($css_prefix, $highlight_min, $highlight_max, $short_word_length) = @_;

    $css_prefix =~ s/[^\w]//g;

    my @parts = (
        qq{StartSel="<span class='$css_prefix'>"},
        "StopSel=</span>"
    );

    push @parts, "MinWords=$highlight_min" if $highlight_min > 0;
    push @parts, "MaxWords=$highlight_max" if $highlight_max > 0;
    push @parts, "ShortWord=$short_word_length" if defined $short_word_length;

    return join(", ", @parts);
}

# Get raw autosuggest data (rows returned from a stored procedure) from the DB.
sub get_suggestions {
    my $editor = shift;
    my $query = shift;
    my $search_class = shift;
    my $org_unit = shift;
    my $css_prefix = shift || 'oils_AS';
    my $highlight_min = int(shift || 0);
    my $highlight_max = int(shift || 0);
    my $short_word_length = shift;

    my $normalization = int(shift || 14);   # 14 is not totally arbitrary.
    # See http://www.postgresql.org/docs/9.0/static/textsearch-controls.html#TEXTSEARCH-RANKING

    my $limit = int(shift || 10);

    $limit = 10 unless $limit > 0;

    my $headline_opts = prepare_headline_opts(
        $css_prefix, $highlight_min, $highlight_max,
        defined $short_word_length ? int($short_word_length) : undef
    );

    return $editor->json_query({
        "from" => [
            "metabib.suggest_browse_entries",
            prepare_for_tsquery($query),
            $search_class,
            $headline_opts,
            $org_unit,
            $limit,
            $normalization
        ]
    });
}

sub suggestions_to_xml {
    my ($suggestions) = @_;

    my $dom = new XML::LibXML::Document("1.0", "UTF-8");
    my $as = $dom->createElement("as");
    $dom->setDocumentElement($as);

    foreach (@$suggestions) {
        my $val = $dom->createElement("val");
        $val->setAttribute("term", $_->{value});
        $val->setAttribute("field", $_->{field});
        $val->appendText($_->{match});
        $as->addChild($val);
    }

    # XML::LibXML::Document::toString() returns an encoded byte string, which
    # is why we don't need to binmode STDOUT, ':utf8'.
    return $dom->toString();
}

sub suggestions_to_json {
    my ($suggestions) = @_;

    return OpenSRF::Utils::JSON->perl2JSON({
        "val" => [
            map {
                +{ term => $_->{value}, field => $_->{field},
                    match => $_->{match} }
            } @$suggestions
        ]
    });
}

# Given data and the Apache request object, this sub picks a sub from a
# dispatch table based on the list of content-type encodings that the client
# has indicated it will accept, and calls that sub, which will deliver
# a response of appropriately encoded data.
sub output_handler {
    my ($r, $data) = @_;

    foreach my $media_range (split /,/, $r->headers_in->{Accept}) {
        $media_range =~ s/;.+$//; # keep type, subtype. lose parameters.

        my ($match) = grep {
            Text::Glob::match_glob($media_range, $_)
        } @_output_handler_types;

        if ($match) {
            return $_output_handler_dispatch->{$match}{code}->($r, $data);
        }
    }

    return Apache2::Const::HTTP_NOT_ACCEPTABLE;
}

sub handler {
    my $r = shift;
    my $cgi = new CGI;

    my $editor = new_editor;
    my $suggestions = get_suggestions(
        $editor,
        map { scalar($cgi->param($_)) } qw(
            query
            search_class
            org_unit
            css_prefix
            highlight_min
            highlight_max
            short_word_length
            normalization
            limit
        )
    );

    if (not $suggestions) {
        $r->log->error(
            "get_suggestions() failed: " . $editor->die_event->{textcode}
        );
        return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;
    }

    $editor->disconnect;

    return output_handler($r, $suggestions);
}

1;