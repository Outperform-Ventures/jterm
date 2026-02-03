#!/usr/bin/env nu

use github.nu

# Vouch - contributor trust management.
#
# Environment variables required:
#
#   GITHUB_TOKEN - GitHub API token with repo access. If this isn't
#     set then we'll attempt to read from `gh` if it exists.
export def main [] {
  print "Usage: vouch <command>"
  print ""
  print "Commands:"
  print "  check-pr          Check if a PR author is a vouched contributor"
  print "  approve-by-issue  Vouch for a contributor via issue comment"
}

# Check if a PR author is a vouched contributor.
#
# Checks if a PR author is a bot, collaborator with write access,
# or in the vouched contributors list. If not vouched, it closes the PR
# with a comment explaining the process.
#
# Outputs a status to stdout: "skipped", "vouched", or "closed"
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./vouch.nu check-pr 123
#
#   # Actually close an unvouched PR
#   ./vouch.nu check-pr 123 --dry-run=false
#
export def "main check-pr" [
  pr_number: int,            # GitHub pull request number
  --repo (-R): string = "ghostty-org/ghostty", # Repository in "owner/repo" format
  --vouched-file: string = ".github/VOUCHED", # Path to vouched contributors file
  --dry-run = true,          # Print what would happen without making changes
] {
  let owner = ($repo | split row "/" | first)
  let repo_name = ($repo | split row "/" | last)

  # Fetch PR data from GitHub API
  let pr_data = github api "get" $"/repos/($owner)/($repo_name)/pulls/($pr_number)"
  let pr_author = $pr_data.user.login
  let default_branch = $pr_data.base.repo.default_branch

  # Skip bots
  if ($pr_author | str ends-with "[bot]") or ($pr_author == "dependabot[bot]") {
    print $"Skipping bot: ($pr_author)"
    print "skipped"
    return
  }

  # Check if user is a collaborator with write access
  let permission = try {
    github api "get" $"/repos/($owner)/($repo_name)/collaborators/($pr_author)/permission" | get permission
  } catch {
    ""
  }

  if ($permission in ["admin", "write"]) {
    print $"($pr_author) is a collaborator with ($permission) access"
    print "vouched"
    return
  }

  # Fetch vouched contributors list from default branch
  let file_data = github api "get" $"/repos/($owner)/($repo_name)/contents/($vouched_file)?ref=($default_branch)"
  let content = $file_data.content | decode base64 | decode utf-8
  let vouched_list = $content
    | lines
    | each { |line| $line | str trim | str downcase }
    | where { |line| ($line | is-not-empty) and (not ($line | str starts-with "#")) }

  if ($pr_author | str downcase) in $vouched_list {
    print $"($pr_author) is in the vouched contributors list"
    print "vouched"
    return
  }

  # Not vouched - close PR with comment
  print $"($pr_author) is not vouched, closing PR"

  let message = $"Hi @($pr_author), thanks for your interest in contributing!

We ask new contributors to open an issue first before submitting a PR. This helps us discuss the approach and avoid wasted effort.

**Next steps:**
1. Open an issue describing what you want to change and why \(keep it concise, write in your human voice, AI slop will be closed\)
2. Once a maintainer vouches for you with `lgtm`, you'll be added to the vouched contributors list
3. Then you can submit your PR

This PR will be closed automatically. See https://github.com/($owner)/($repo_name)/blob/($default_branch)/CONTRIBUTING.md for more details."

  if $dry_run {
    print "(dry-run) Would post comment and close PR"
    print "closed"
    return
  }

  # Post comment
  github api "post" $"/repos/($owner)/($repo_name)/issues/($pr_number)/comments" {
    body: $message
  }

  # Close the PR
  github api "patch" $"/repos/($owner)/($repo_name)/pulls/($pr_number)" {
    state: "closed"
  }

  print "closed"
}

# Vouch for a contributor by adding them to the VOUCHED file.
#
# This checks if a comment matches "lgtm", verifies the commenter has
# write access, and adds the issue author to the vouched list if not already 
# present.
#
# Outputs a status to stdout: "skipped", "already", or "added"
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./vouch.nu approve-by-issue 123 456789
#
#   # Actually vouch for a contributor
#   ./vouch.nu approve-by-issue 123 456789 --dry-run=false
#
export def "main approve-by-issue" [
  issue_id: int,           # GitHub issue number
  comment_id: int,         # GitHub comment ID
  --repo (-R): string = "ghostty-org/ghostty", # Repository in "owner/repo" format
  --vouched-file: string = ".github/VOUCHED", # Path to vouched contributors file
  --dry-run = true,        # Print what would happen without making changes
] {
  let owner = ($repo | split row "/" | first)
  let repo_name = ($repo | split row "/" | last)

  # Fetch issue and comment data from GitHub API
  let issue_data = github api "get" $"/repos/($owner)/($repo_name)/issues/($issue_id)"
  let comment_data = github api "get" $"/repos/($owner)/($repo_name)/issues/comments/($comment_id)"

  let issue_author = $issue_data.user.login
  let commenter = $comment_data.user.login
  let comment_body = ($comment_data.body | default "")

  # Check if comment matches "lgtm"
  if not ($comment_body | str trim | parse -r '(?i)^\s*lgtm\b' | is-not-empty) {
    print "Comment does not match lgtm"
    print "skipped"
    return
  }

  # Check if commenter has write access
  let permission = try {
    github api "get" $"/repos/($owner)/($repo_name)/collaborators/($commenter)/permission" | get permission
  } catch {
    print $"($commenter) does not have collaborator access"
    print "skipped"
    return
  }

  if not ($permission in ["admin", "write"]) {
    print $"($commenter) does not have write access"
    print "skipped"
    return
  }

  # Read vouched contributors file
  let content = open $vouched_file
  let vouched_list = $content
    | lines
    | each { |line| $line | str trim | str downcase }
    | where { |line| ($line | is-not-empty) and (not ($line | str starts-with "#")) }

  # Check if already vouched
  if ($issue_author | str downcase) in $vouched_list {
    print $"($issue_author) is already vouched"

    if not $dry_run {
      github api "post" $"/repos/($owner)/($repo_name)/issues/($issue_id)/comments" {
        body: $"@($issue_author) is already in the vouched contributors list."
      }
    } else {
      print "(dry-run) Would post 'already vouched' comment"
    }

    print "already"
    return
  }

  if $dry_run {
    print $"(dry-run) Would add ($issue_author) to ($vouched_file)"
    print "added"
    return
  }

  # Add contributor to the file and sort (preserving comments at top)
  let lines = $content | lines
  let comments = $lines | where { |line| ($line | str starts-with "#") or ($line | str trim | is-empty) }
  let contributors = $lines
    | where { |line| not (($line | str starts-with "#") or ($line | str trim | is-empty)) }
    | append $issue_author
    | sort -i
  let new_content = ($comments | append $contributors | str join "\n") + "\n"
  $new_content | save -f $vouched_file

  print $"Added ($issue_author) to vouched contributors"
  print "added"
}
