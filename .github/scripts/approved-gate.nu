#!/usr/bin/env nu

use github.nu

# Approved contributor gate commands.
#
# Environment variables required:
#   GITHUB_TOKEN - GitHub API token with repo access. If this isn't
#     set then we'll attempt to read from `gh` if it exists.
def main [] {
  print "Usage: approved-gate <command>"
  print ""
  print "Commands:"
  print "  pr    Check if a PR author is an approved contributor"
}

# Check if a PR author is an approved contributor.
#
# Checks if a PR author is a bot, collaborator with write access,
# or in the approved contributors list. If not approved, it closes the PR
# with a comment explaining the process.
#
# Outputs a status to stdout: "skipped", "approved", or "closed"
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./approved-gate.nu pr 123
#
#   # Actually close an unapproved PR
#   ./approved-gate.nu pr 123 --dry-run=false
#
def "main pr" [
  pr_number: int,            # GitHub pull request number
  --repo (-R): string = "ghostty-org/ghostty", # Repository in "owner/repo" format
  --approved-file: string = ".github/APPROVED_CONTRIBUTORS", # Path to approved contributors file
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
    print "approved"
    return
  }

  # Fetch approved contributors list from default branch
  let file_data = github api "get" $"/repos/($owner)/($repo_name)/contents/($approved_file)?ref=($default_branch)"
  let content = $file_data.content | decode base64 | decode utf-8
  let approved_list = $content
    | lines
    | each { |line| $line | str trim | str downcase }
    | where { |line| ($line | is-not-empty) and (not ($line | str starts-with "#")) }

  if ($pr_author | str downcase) in $approved_list {
    print $"($pr_author) is in the approved contributors list"
    print "approved"
    return
  }

  # Not approved - close PR with comment
  print $"($pr_author) is not approved, closing PR"

  let message = $"Hi @($pr_author), thanks for your interest in contributing!

We ask new contributors to open an issue first before submitting a PR. This helps us discuss the approach and avoid wasted effort.

**Next steps:**
1. Open an issue describing what you want to change and why \(keep it concise, write in your human voice, AI slop will be closed\)
2. Once a maintainer approves with `lgtm`, you'll be added to the approved contributors list
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
