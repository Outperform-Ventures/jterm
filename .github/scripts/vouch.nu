#!/usr/bin/env nu

use github.nu

# Vouch for a contributor by adding them to the VOUCHED file.
#
# This script checks if a comment matches "lgtm", verifies the commenter has
# write access, and adds the issue author to the vouched list if not already 
# present.
#
# Environment variables required:
#   GITHUB_TOKEN - GitHub API token with repo access. If this isn't
#     set then we'll attempt to read from `gh` if it exists.
#
# Outputs a status to stdout: "skipped", "already", or "added"
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./vouch.nu 123 456789
#
#   # Actually vouch for a contributor
#   ./vouch.nu 123 456789 --dry-run=false
#
def main [
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
