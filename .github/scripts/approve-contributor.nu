#!/usr/bin/env nu

# Approve a contributor by adding them to the APPROVED_CONTRIBUTORS file.
#
# This script checks if a comment matches "lgtm", verifies the commenter has
# write access, and adds the issue author to the approved list if not already 
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
#   ./approve-contributor.nu 123 456789
#
#   # Actually approve a contributor
#   ./approve-contributor.nu 123 456789 --dry-run=false
#
def main [
  issue_id: int,           # GitHub issue number
  comment_id: int,         # GitHub comment ID
  --repo (-R): string = "ghostty-org/ghostty", # Repository in "owner/repo" format
  --approved-file: string = ".github/APPROVED_CONTRIBUTORS", # Path to approved contributors file
  --dry-run = true,        # Print what would happen without making changes
] {
  let owner = ($repo | split row "/" | first)
  let repo_name = ($repo | split row "/" | last)

  # Fetch issue and comment data from GitHub API
  let issue_data = github-api "get" $"/repos/($owner)/($repo_name)/issues/($issue_id)"
  let comment_data = github-api "get" $"/repos/($owner)/($repo_name)/issues/comments/($comment_id)"

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
    github-api "get" $"/repos/($owner)/($repo_name)/collaborators/($commenter)/permission" | get permission
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

  # Read approved contributors file
  let content = open $approved_file
  let approved_list = $content
    | lines
    | each { |line| $line | str trim | str downcase }
    | where { |line| ($line | is-not-empty) and (not ($line | str starts-with "#")) }

  # Check if already approved
  if ($issue_author | str downcase) in $approved_list {
    print $"($issue_author) is already approved"

    if not $dry_run {
      github-api "post" $"/repos/($owner)/($repo_name)/issues/($issue_id)/comments" {
        body: $"@($issue_author) is already in the approved contributors list."
      }
    } else {
      print "(dry-run) Would post 'already approved' comment"
    }

    print "already"
    return
  }

  if $dry_run {
    print $"(dry-run) Would add ($issue_author) to ($approved_file)"
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
  $new_content | save -f $approved_file

  print $"Added ($issue_author) to approved contributors"
  print "added"
}

# Make a GitHub API request with proper headers
def github-api [
  method: string,  # HTTP method (get, post, etc.)
  endpoint: string # API endpoint (e.g., /repos/owner/repo/issues/1/comments)
  body?: record    # Optional request body
] {
  let url = $"https://api.github.com($endpoint)"
  let headers = [
    Authorization $"Bearer (get-github-token)"
    Accept "application/vnd.github+json"
    X-GitHub-Api-Version "2022-11-28"
  ]

  match $method {
    "get" => { http get $url --headers $headers },
    "post" => { http post $url --headers $headers $body },
    _ => { error make { msg: $"Unsupported HTTP method: ($method)" } }
  }
}

# Get GitHub token from environment or gh CLI (cached in env)
def get-github-token [] {
  if ($env.GITHUB_TOKEN? | is-not-empty) {
    return $env.GITHUB_TOKEN
  } 

  $env.GITHUB_TOKEN = (gh auth token | str trim)
  $env.GITHUB_TOKEN
}
