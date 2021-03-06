package API::Git;
use strict;use warnings;
use 5.010;
use Carp;
use Exporter 'import';
use IPC::System::Simple qw/capture system EXIT_ANY $EXITVAL/;
use List::MoreUtils qw/any uniq/;
use Ticket qw/cfg %EXIT/;

our @EXPORT_OK = qw/
    cd_to_repo_root
    checkout_branch
    checkout_branch_assert
    fetch_remote
    get_branch
    get_current_branch
    get_deltas
    get_issuekeys_from_branch
    get_issuekeys_from_commit
    get_log_diff
    get_rev
    get_tag get_previous_tag
    is_rev_tagged
    list_tags
    merge_no_ff
    pull_branch
    publish_branch
    repo_root
    rev_contained_in
    tag_rev
/;

my $DELIMITER = 'DeliMdElIM';
my ($REMOTE, $TICKET_PATTERN) = cfg(qw/remote ticket_pattern/);

sub _match_against_ticket_pattern {#{{{
    my @keys = $_[0] =~ /$TICKET_PATTERN/g;
    return @keys;
}#}}}

sub is_rev_tagged {
    my $rev = $_[0] // 'HEAD';
    return int(! system(EXIT_ANY, "git describe $rev --exact-match 2>/dev/null"));
}

sub repo_root {
    chomp(my $root_dir = capture(qw/git rev-parse --show-toplevel/));
    return $root_dir;
}

sub cd_to_repo_root {#{{{
    chdir repo_root;
}#}}}

sub get_current_branch { get_branch('HEAD') }

sub get_issuekeys_from_branch {#{{{
    return _match_against_ticket_pattern( get_branch($_[0] // 'HEAD') );
}#}}}

sub get_issuekeys_from_commit {#{{{
    my ($rev) = @_;

    my $format = join $DELIMITER, qw/%B %an %h/;

    my @log = (qw/git log -1/, "--format=$format");
    push @log, defined $rev
        ? $rev
        : '--no-merges';

    my ($message, $author, $short_rev) = split $DELIMITER, capture(@log);

    my @keys = _match_against_ticket_pattern($message);
    if (! @keys) {
        $rev //= $short_rev;
        chomp $rev;
        croak "No tickets found in $rev authored by $author.";
    }
    return @keys;
}#}}}

sub get_branch {
    chomp(my $branch = capture(qw/git rev-parse --abbrev-ref/, $_[0]));
    return $branch;
}

sub list_tags {
    my ($pattern) = @_;
    my @cmd = qw/git tag -l/;
    push @cmd, $pattern if $pattern;
    chomp(my @tags = capture @cmd);
    return @tags;
}

# maps rc versions to their major version
sub get_versions_for_span {
    my ($since, $until) = @_;
    return uniq map { /\b(v\d+\.\d+\.(?:rc)?\d+)\b/g }
        capture (qw/git log --oneline --pretty=%d/, $since.'..'.$until);
}

sub get_rev { chomp( my $rev = capture(qw/git rev-parse/, $_[0]) ); $rev }

my $fetched_tags = 0;
sub fetch_remote_tags {#{{{
    fetch_remote();
    return if $fetched_tags;
    if (system(EXIT_ANY, qw/git fetch -q --tags/, $REMOTE)) {
        exit $EXIT{EXTERNAL_SERVICE_DOWN};
    }
    $fetched_tags = 1;
}#}}}

my $fetched = 0;
sub fetch_remote {#{{{
    return if $fetched;
    if (system(EXIT_ANY, qw/git fetch -q/, $REMOTE)) {
        exit $EXIT{EXTERNAL_SERVICE_DOWN};
    }
    $fetched = 1;
}#}}}

sub rev_contained_in {#{{{
    my ($needle, $stack) = @_;
    return any {/^\s*$stack\s*$/} capture(qw/git branch --remote --contains/, $needle);
}#}}}

# XXX May checkout to different branch than git was on prior to the call
# Never assume branch does not change, use checkout_branch()
sub pull_branch {#{{{
    my ($branch) = @_;

    fetch_remote;
    my $remote_ref = $REMOTE.'/'.$branch;

    if (get_log_diff($branch, $remote_ref)) {
        checkout_branch($branch);
        system(qw/git merge -q/, $remote_ref);
        return $branch;
    }
    return;
}#}}}

sub publish_branch {
    my ($rev) = @_;
    my $branch = get_branch($rev // 'HEAD');
    system qw/git push --set-upstream/, $REMOTE, $branch;
}

my $HEAD = 'HEAD';
sub checkout_branch {#{{{
    my ($branch) = @_;
    return if $branch eq $HEAD;
    system(qw/git checkout -q/, $branch);
    return $HEAD = $branch;
}#}}}

sub checkout_branch_assert {#{{{
    my ($branch, $start_point) = @_;

    my $remote_branch = $branch !~ /^$REMOTE/
        ? $REMOTE.'/'. $branch
        : $branch;

    my $branch_exists = length capture(qw/git branch --list --remote/, $remote_branch);

    my @checkout = qw/git checkout/;
    push @checkout, '-b' unless $branch_exists;
    push @checkout, $branch;
    # if branch already exist, providing start_point will break
    # it's expected because user needs to know that fact and reason behind it)
    if ($start_point) {
        push @checkout, $start_point;

        # prevent tracking start point, but only if creating new branch
        # so that we can benefit from smart behavior of git checkout branch when origin/branch is present (when tracking occurs and is welcomed)
        # and at the same time prevent users from mindlessly push to start_point, which is rarely what we want (because it was tracked by default)
        push @checkout, '--no-track' unless $branch_exists;
    }

    system @checkout;
    $HEAD = $branch;
}#}}}

sub get_tag {#{{{
    chomp(my $tag = capture(qw/git describe --abbrev=0/, $_[0] // 'HEAD'));
    return $tag;
}#}}}

# get all files changed since $until branched from $since except those in $except
# can be limited to files belonging to @paths
sub get_deltas {#{{{
    my ($since, $until, $except, @paths) = @_;

    my @cmd = (qw/git log --name-only --pretty=format:/, $since.'..'.$until);
    push @cmd, ('--not' => $except) if $except;
    push @cmd, ('--', @paths) if @paths;

    my @files = uniq grep {/\S/} capture(@cmd);
    chomp @files;
    return @files;
}#}}}

sub get_log_diff {#{{{
    my ($a_rev, $b_rev) = @_;
    my @diff = capture(qw/git log --oneline/, $a_rev .'..'. $b_rev);
    return @diff;
}#}}}

sub get_previous_tag {#{{{
    my ($tag) = @_;

    $tag //= get_tag;
    return get_tag($tag .'^');
}#}}}

sub merge_no_ff {#{{{
    my ($branch, $resolver) = @_;

    my $tip = capture(qw/git rev-parse/, $branch);
    my $last_common = capture(qw/git merge-base HEAD/, $branch);
    if ($tip eq $last_common) {
        return 'Already up to date';
    }

    #FIXME This is so ugly, and possibly leaking
    # Unfortunately git-merge prints to STDOUT only, and has no builtin way of filtering errors
    my @problems = grep {
        /^(?:error:|fatal:|CONFLICT)/
    } capture(EXIT_ANY, qw/git merge --no-ff/, $branch);
    if (my $has_problems = $EXITVAL + scalar @problems) {
        if (scalar @problems) {
            carp join '', @problems;
        }
        if ($resolver and $resolver->()) {
            return 0;
        }

        # Hopefully this suffices to reset the working dir after any error encountered
        system(qw/git reset --hard --quiet/);
        # Capture instead of system to hide warnings "not removing directory ..."
        capture(qw/git clean --force --quiet/);
        return $has_problems;
    }
    return 0;
}#}}}

sub tag_rev {#{{{
    my ($version, $revision) = @_;

    my @cmd = (qw/git tag -a -m/, $version, $version);
    push @cmd, $revision if $revision;
    system @cmd;
}#}}}

1;
