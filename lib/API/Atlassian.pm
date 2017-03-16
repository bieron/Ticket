package API::Atlassian; #{{{
use strict; use warnings;
use 5.010;
use Carp;
use Exporter 'import';
use IPC::System::Simple 'capture';
use JSON::XS;
use List::MoreUtils 'any';

use Ticket qw/cfg %EXIT/;

our @EXPORT_OK = qw/
    request_response

    get_plan_fields
    get_rev_plans
    get_rev_plans_pretty
    is_plan_green
    run_plan_for_rev

    create_issue
    set_issue_fields
    get_issue_fields
    assign_to_issue
    get_issue_transitions
    transition_issue
    link_issues
    log_work_for_issue
    comment_issue
    attach_file_to_issue
    search_for_issues

    create_version
    get_versions
    modify_version_by_id
/;
our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);#}}}

my $HTTP_NO_CONTENT = 204;
my $HTTP_UNAUTHORIZED = 401;
my $HTTP_SERVICE_UNAVAILABLE = 503;

my ($ci_tool_url, $tracker_url, $project_key) = cfg qw/ci_tool_host tracker_host project_key/;
$tracker_url .= 'rest/api/2/';
my $issue_url = $tracker_url . 'issue/';
my $ci_result_url = $ci_tool_url . 'rest/api/latest/result/';

sub attach_file_to_issue {#{{{
    my ($key, $attachment_path) = @_;

    my $attach_url = $issue_url . $key .'/attachments';

    return _curl(
        $attach_url,
        '-X' => 'POST',
        '-H' => 'X-Atlassian-Token: no-check',
        '-F' => 'file=@'. $attachment_path,
    );
}#}}}

sub request_response {#{{{
    my %params = (
        method => 'GET',
        content_type => 'application/json',
        @_
    );
    croak 'Required parameter "url" not provided.' unless defined $params{url};

    if (my $query = $params{query}) {
        $params{url} .= '?' . join '&', map {
            $_ .'='. $query->{$_}
        } keys %{$query};
    }

    my @cmd = (
        '-X' => $params{method},
        '-H' => 'Content-Type: ' . $params{content_type},
    );

    if ($params{json}) {
        push @cmd, (
            '-d', encode_json($params{json}),
        );
    }

    my ($code, $response) = _curl($params{url}, @cmd);
    return if $code == $HTTP_NO_CONTENT;

    if ($params{raw}) {
        return wantarray ? @$response : join '', @$response;
    }

    #body is [expected to be] in json format or empty - so it's in the last line
    my $body = $response->[-1];

    if ($body =~ /^\s+$/ and uc $params{method} ne 'GET') {
        #dont decode empty body but fail if didn't GET anything
        return;
    }

    return decode_json($body);
}#}}}

sub _curl {#{{{
    my ($url, @cmd) = @_;
    unshift @cmd, qw/curl --silent -D-/, Ticket::get_authorization_data($url);
    push @cmd, $url;
#    err join ' ', @cmd;

    my @response = capture(@cmd);
    #HTTP code is in the first line
    my ($code) = $response[0] =~ m|HTTP/\d\.\d (\d{3})|;

    if ($code > 299) {
        say STDERR $response[0];
        if ($code == $HTTP_UNAUTHORIZED) {
            Ticket::clear_authorization_data($url);
            exit $EXIT{GENERIC};
        } elsif ($code == $HTTP_SERVICE_UNAVAILABLE) {
            say join '', @response;
            exit $EXIT{EXTERNAL_SERVICE_DOWN};
        }
        croak join '', @response;
    }
    return ($code, \@response);
}#}}}

### bamboo ######

sub get_plan_fields {#{{{
    my ($key, @fields) = @_;

    return request_response(
        url => $ci_result_url . $key .'.json?expand=' . (join ',', @fields)
    );
}#}}}

sub get_rev_plans {#{{{
    my ($rev) = @_;

    return request_response(
        url => $ci_result_url .'byChangeset/'. $rev .'.json'
    )->{results}{result};
}#}}}

sub is_plan_green {#{{{
    my ($rev, $match) = @_;

    return any {
        $_->{plan}{key} =~ /$match/ and $_->{buildState} eq 'Successful'
    } @{ get_rev_plans($rev) // []};
}#}}}

#FIXME it's too high level of abstraction for this api module
sub get_rev_plans_pretty {#{{{
    my ($rev, $verbose) = @_;

    my %plan_status;
    for (@{ get_rev_plans($rev) }) {
        my %plan = (
            plan   => $_->{plan}{key},
            state  => $_->{lifeCycleState},
            ok     => $_->{buildState} eq 'Successful',
            result => $_->{buildState},
        );
        if ($verbose && $_->{lifeCycleState} eq 'InProgress') {
            @plan{qw/
                progress
                time_remaining
                time_spent
            /} = @{ get_plan_progress( $_->{key} ) }{qw/
                percentageCompletedPretty
                prettyTimeRemaining
                prettyBuildTime
            /};
        }
        $plan_status{ $_->{key} } = \%plan;
    }
    return \%plan_status;
}#}}}

sub get_plan_progress {#{{{
    my ($plan) = @_;

    return request_response(
        url => $ci_result_url . $plan .'.json'
    )->{progress};
}#}}}

sub run_plan_for_rev {#{{{
    my ($plan, $rev, $force) = @_;
    return request_response(
        method => 'POST',
        url => $ci_tool_url ."rest/api/latest/queue/$plan.json?customRevision=$rev",
        content_type => '',
    )->{buildResultKey};
}#}}}

### jira issue   ######

sub create_issue {#{{{
    my ($issue_data) = @_;

    $issue_data->{fields}{project} //= {key => $project_key};

    return request_response(
        method => 'POST',
        url => $issue_url,
        json => $issue_data,
    )->{key};
}#}}}

sub get_issue_fields {#{{{
    my ($key, $fields) = @_;

    my $fields_query = join ',', @{$fields};
    my $rsvp = request_response(
        method => 'GET',
        url => $issue_url . $key,
        query => {fields => $fields_query},
    );
    croak "Unsupported fields: $fields_query" unless $rsvp->{fields};
    return $rsvp->{fields};
}#}}}

sub set_issue_fields {#{{{
    my ($key, $payload) = @_;

    return request_response(
        method => 'PUT',
        url => $issue_url . $key,
        json => $payload,
    );
}#}}}

sub assign_to_issue {#{{{
    my ($key, $assignee) = @_;

    return request_response(
        method => 'PUT',
        url => $issue_url . $key .'/assignee',
        json => {name => $assignee},
    );
}#}}}

sub get_issue_transitions {#{{{
    my ($key) = @_;

    return request_response(
        url => $issue_url . $key .'/transitions',
    )->{transitions};
}#}}}

sub transition_issue {#{{{
    my ($key, $transition_id) = @_;

    return request_response(
        method => 'POST',
        url => $issue_url . $key .'/transitions',
        json => {transition => {id => $transition_id}},
    );
}#}}}

sub link_issues {# {{{
    my ($a, $relation, $b) = @_;

    return request_response(
        method => 'POST',
        url => $tracker_url . 'issueLink',
        json => {
            type => {name => $relation},
            inwardIssue  => {key => $a},
            outwardIssue => {key => $b},
        },
    );
}#}}}

sub log_work_for_issue {#{{{
    my ($key, $time, $date) = @_;

    my %json = (
        timeSpent => $time,
    );
    $json{started} = $date if defined $date;

    return request_response(
        url => (sprintf '%s%s/worklog?', $issue_url, $key),
        method => 'POST',
        json => \%json
    );
}#}}}

sub comment_issue {#{{{
    my ($key, $comment) = @_;

    return request_response(
        method => 'POST',
        url => $issue_url . $key .'/comment',
        json => { body => $comment },
    );
}#}}}

sub search_for_issues {#{{{
    my %params = @_;

#   jql startAt limit fields
    return request_response(
        method => 'POST',
        url    => $tracker_url . 'search/',
        json   => \%params,
    )->{issues};
}#}}}

### jira user

sub get_user {
    return request_response(
        method => 'GET',
        url    => $tracker_url .'user?key='. $_[0]
    );
}

### jira version ######

sub create_version {#{{{
    my %params = (@_);

    return request_response(
        method => 'POST',
        url    => $tracker_url . 'version',
        json   => {
            archived => \0,
            released => \0,
            project  => $project_key,
            %params,
        },
    )->{id};
}#}}}

sub get_versions {#{{{
    return request_response(
        method => 'GET',
        url    => $tracker_url .'project/'. $project_key .'/versions'
    );
}#}}}

sub modify_version_by_id {#{{{
    my ($id, %params) = @_;

    return request_response(
        url => $tracker_url .'version/'. $id,
        method => 'PUT',
        json => \%params,
    );
}#}}}

### interface translators ####

sub in_complex { {name => $_[0]} }
sub in_complex_list { [map { in_complex($_) } split ',', $_[0]] }

sub out_complex { if ($_[0]) { $_[0]{name} } }
sub out_complex_list {
    ref $_[0] && @{ $_[0] }
        ? join ',', map { out_complex($_) } @{$_[0]}
        : undef
}

1;
