#!/usr/bin/env nu

# Main command to update agentic skills catalog
def main [
  --catalog-path: string = "skills-catalog.json"
  --repos (-r): any = "all"
  --interactive (-i)
] {
  let script_dir = ($env.CURRENT_FILE | path dirname)
  let is_nix_store = ($script_dir | str starts-with "/nix/store")

  # Resolve the catalog path
  let catalog_expanded = if ($catalog_path | str starts-with "/") or ($catalog_path | str starts-with "~") {
    $catalog_path | path expand
  } else if ($catalog_path != "skills-catalog.json" and $catalog_path != "modules/agentic-skills/skills-catalog.json") {
    # A custom relative path was provided
    $catalog_path | path expand
  } else {
    # Default catalog path checking
    if ($env.PWD | path join "skills-catalog.json" | path exists) {
      $env.PWD | path join "skills-catalog.json" | path expand
    } else if (not $is_nix_store) and ($script_dir | path join "skills-catalog.json" | path exists) {
      $script_dir | path join "skills-catalog.json" | path expand
    } else {
      print "Error: skills-catalog.json not found in the current directory."
      print "Please run this command from the root of the agentic-skills repository, or specify the path via --catalog-path."
      return
    }
  }

  let initial_catalog = if ($catalog_expanded | path exists) {
    open $catalog_expanded
  } else {
    { repos: {} }
  }

  print $"Updating skills catalog at ($catalog_expanded)..."

  # Define repositories using declarative metadata
  let repo_configs = [
    { key: "anthropics", owner: "anthropics", repo: "skills", skills_path: "skills" },
    { key: "actionbook", owner: "actionbook", repo: "rust-skills", skills_path: "skills" },
    { key: "vercel", owner: "vercel-labs", repo: "agent-skills", skills_path: "skills" },
    { key: "openai", owner: "openai", repo: "skills", skills_path: "skills" },
    { key: "addyosmani", owner: "addyosmani", repo: "agent-skills", skills_path: "skills" },
    { key: "mindrally", owner: "Mindrally", repo: "skills", skills_path: "skills" },
    { key: "hypergiant", owner: "gohypergiant", repo: "agent-skills", skills_path: "skills" },
    { key: "cloudflare", owner: "cloudflare", repo: "skills", skills_path: "skills" },
    { key: "stripe", owner: "stripe", repo: "ai", skills_path: "skills" },
    { key: "pocock", owner: "mattpocock", repo: "skills", skills_path: "skills" },
    { key: "cursor", owner: "cursor", repo: "plugins", skills_path: "" },
    { key: "lucianghinda", owner: "lucianghinda", repo: "superpowers-ruby", skills_path: "skills" },
    { key: "palkan", owner: "palkan", repo: "skills", skills_path: "skills", branch: "master" }
  ]

  let all_repo_keys = ($repo_configs | get key)

  let parsed_repos = if ($repos | describe) =~ "list" {
    $repos
  } else if ($repos | describe) =~ "string" {
    if $repos == "all" {
      ["all"]
    } else {
      $repos | split row "," | each { str trim }
    }
  } else {
    ["all"]
  }

  let keys_to_update = if $interactive {
    let selected = ($all_repo_keys | input list -m "Select repositories to update:")
    if ($selected | is-empty) {
      print "No repositories selected. Exiting."
      return
    }
    $selected
  } else if ("all" in $parsed_repos) {
    $all_repo_keys
  } else {
    $parsed_repos
  }

  let invalid_keys = ($keys_to_update | where { $in not-in $all_repo_keys })
  if ($invalid_keys | length) > 0 {
    print $"Error: Invalid repository key\(s\): ($invalid_keys | str join ', '). Valid keys are: ($all_repo_keys | str join ', ')"
    return
  }

  # PURELY FUNCTIONAL: Map repo configs to fetched data using 'each'
  let fetched_repos = ($repo_configs | each { |config|
    let key = $config.key
    if ($key in $keys_to_update) {
      print $"Fetching repo: ($config.owner)/($config.repo)..."
      let result = try { fetch-repo-skills $config } catch { |err|
        print $"Error fetching ($config.owner)/($config.repo): ($err.msg). Skipping."
        null
      }

      if $result != null {
        { key: $key, val: $result }
      } else if ("repos" in ($initial_catalog | columns)) and ($key in ($initial_catalog.repos | columns)) {
        print $"  Using cached data for ($key)."
        { key: $key, val: ($initial_catalog.repos | get $key) }
      } else {
        null
      }
    } else {
      # Preserve existing
      if ("repos" in ($initial_catalog | columns)) and ($key in ($initial_catalog.repos | columns)) {
        { key: $key, val: ($initial_catalog.repos | get $key) }
      } else {
        null
      }
    }
  } | where { $in != null } | reduce -f {} { |item, acc| $acc | upsert $item.key $item.val })

  # PURELY FUNCTIONAL: Resolve collisions globally using list transformations
  let all_skills_flat = ($fetched_repos | transpose repo_key repo_data | each { |row|
    $row.repo_data.skills | transpose skill_name skill_data | each { |s|
      {
        repo_key: $row.repo_key,
        orig_name: $s.skill_name,
        description: $s.skill_data.description,
        path: $s.skill_data.path
      }
    }
  } | flatten)

  let grouped_skills = ($all_skills_flat | group-by orig_name)

  let resolved_skills = ($grouped_skills | transpose name list | each { |group|
    if ($group.list | length) > 1 {
      # Collision! Prefix with repo key
      $group.list | each { |item|
        $item | upsert resolved_name $"($item.repo_key)-($item.orig_name)"
      }
    } else {
      $group.list | each { |item|
        $item | upsert resolved_name $item.orig_name
      }
    }
  } | flatten)

  # PURELY FUNCTIONAL: Rebuild final repositories structure
  let final_repos = ($fetched_repos | transpose repo_key repo_data | each { |row|
    let repo_skills = ($resolved_skills | where repo_key == $row.repo_key | each { |s|
      {
        key: $s.resolved_name,
        val: {
          name: $s.resolved_name,
          description: $s.description,
          path: $s.path
        }
      }
    } | reduce -f {} { |item, acc| $acc | upsert $item.key $item.val })

    {
      key: $row.repo_key,
      val: ($row.repo_data | upsert skills $repo_skills)
    }
  } | reduce -f {} { |item, acc| $acc | upsert $item.key $item.val })

  { repos: $final_repos } | save -f $catalog_expanded
  print "Skills catalog successfully updated!"
}

# Unified repo skill fetcher
def fetch-repo-skills [config: record] {
  let owner = $config.owner
  let repo = $config.repo
  let skills_path = $config.skills_path
  let branch = ($config | get -o branch | default "main")

  # 1. Get the latest commit SHA via the GitHub API
  let commits_url = $"https://api.github.com/repos/($owner)/($repo)/commits/($branch)"
  let rev = (http get -H ["Accept" "application/vnd.github.v3+json"] $commits_url | get sha)

  # 2. Compute Nix SRI hash and store path via nix-prefetch-url
  let archive_url = $"https://github.com/($owner)/($repo)/archive/($rev).tar.gz"
  let prefetch = (nix-prefetch-url --unpack --print-path $archive_url | lines)
  let raw_hash = ($prefetch | get 0 | str trim)
  let store_path = ($prefetch | get 1 | str trim)

  let hash = (nix hash convert --hash-algo sha256 --to sri $raw_hash | str trim)

  # 3. Scan for SKILL.md files
  let common_excludes = ["**/node_modules/**" "**/.git/**" "**/vendor/**"]
  let skill_files = if ($skills_path | is-empty) {
    glob $"($store_path)/**/SKILL.md" --depth 4 --exclude $common_excludes
  } else {
    let scan_root = ($store_path | path join $skills_path)
    glob $"($scan_root)/**/SKILL.md" --depth 3 --exclude $common_excludes
  }

  # PURELY FUNCTIONAL: Map files to records. Intermediate strings dropped every iteration.
  let parsed_skills_list = ($skill_files | each { |skill_file|
    let skill_dir = ($skill_file | path dirname)
    let skill_name = ($skill_dir | path basename)
    let relative_path = ($skill_dir | path relative-to $store_path | into string)

    let content = (open -r $skill_file)
    let desc = (parse-skill-description $content)

    if ($desc | is-empty) {
      return null
    }

    {
      original_name: $skill_name,
      description: $desc,
      path: $relative_path
    }
  } | where { $in != null })

  # Internal collision resolution (within a single repo)
  let skills = ($parsed_skills_list | reduce -f {} { |item, acc|
    mut final_name = $item.original_name
    if ($final_name in ($acc | columns)) {
      let subproject = ($item.path | split row "/" | first)
      $final_name = $"($subproject)-($item.original_name)"
    }
    $acc | upsert $final_name {
      name: $final_name,
      description: $item.description,
      path: $item.path
    }
  })

  # Clean up the store path immediately
  try { nix-store --delete $store_path o+e>| ignore } catch {}

  {
    owner: $owner,
    repo: $repo,
    rev: $rev,
    hash: $hash,
    skills: $skills
  }
}

# Helper to extract the description from YAML frontmatter in SKILL.md
def parse-skill-description [md_content: string] {
  # 1. Try to extract YAML frontmatter (for Markdown files with --- blocks)
  let parts = ($md_content | split row "---")

  let fm = if ($parts | length) >= 3 {
    let raw = ($parts | get 1)
    try { $raw | from yaml } catch { null }
  } else {
    # 2. Try to parse entire content as YAML (for pure YAML skill files)
    try { $md_content | from yaml } catch { null }
  }

  # Skip if YAML is unparseable or not a record
  if ($fm | describe) !~ "record" {
    return null
  }

  # Use column access for description
  if "description" in ($fm | columns) {
    return ($fm.description | str trim)
  }

  null
}
