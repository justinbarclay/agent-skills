# Declarative agent skill management via Nix.
#
# Pinned hashes are in skills-catalog.json.
# To update the catalog: run `update-skills`, then rebuild with `home-manager switch`.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.modules.agentic-skills;

  # Load the catalog file
  catalogFile = ./skills-catalog.json;
  catalog =
    if builtins.pathExists catalogFile
    then builtins.fromJSON (builtins.readFile catalogFile)
    else { repos = { }; };

  # Default agent installation directories relative to home directory
  agentTargets = {
    antigravity = ".gemini/antigravity/skills";
    claude = ".claude/skills";
    codex = ".agents/skills";
    cursor = ".cursor/skills";
    gemini = ".gemini/skills";
    copilot = ".copilot/skills";
    eca = ".config/eca/skills";
    opencode = ".config/opencode/skills";
    windsurf = ".codeium/windsurf/skills";
    kiro = ".kiro/skills";
  };

  # 1. Fetch repositories defined in the catalog using fetchFromGitHub.
  fetchedRepos = lib.mapAttrs
    (repoKey: repoData:
      pkgs.fetchFromGitHub {
        owner = repoData.owner;
        repo = repoData.repo;
        rev = repoData.rev;
        hash = repoData.hash;
      }
    )
    catalog.repos;

  # Flatten catalog into a single attrset of skill names mapping to their data
  # Since the update script enforces uniqueness, we can safely merge them.
  allSkills = lib.foldl'
    (acc: repoKey:
      let
        repoData = catalog.repos.${repoKey};
        skills = repoData.skills or { };
        owner = repoData.owner or "";
        repo = repoData.repo or "";
        repoUrl = if owner != "" && repo != "" then "https://github.com/${owner}/${repo}" else "";
        mappedSkills = lib.mapAttrs'
          (skillKey: skillData:
            lib.nameValuePair skillKey (skillData // {
              inherit repoKey repoUrl;
            })
          )
          skills;
      in
      acc // mappedSkills
    )
    { }
    (builtins.attrNames (catalog.repos or { }));

  # 2. Generate home.file definitions for each active agent target.
  activeAgents = lib.filterAttrs (name: agentConf: agentConf.enable) cfg.agents;

  # Filter enabled skills from user config
  enabledSkills = lib.filterAttrs (name: skillConf: skillConf.enable) cfg.skills;

  # Build the file configurations for a single agent
  skillFilesForAgent = agentName: agentConf:
    let
      # Skills that target this agent (agents is empty [] OR agentName is in agents)
      targetedSkills = lib.filterAttrs
        (skillName: skillConf:
          skillConf.agents == [ ] || lib.elem agentName skillConf.agents
        )
        enabledSkills;
    in
    lib.mapAttrs'
      (skillName: skillConf:
        let
          skillData = allSkills.${skillName} or (throw "Skill '${skillName}' not found in skills-catalog.json");
          repoKey = skillData.repoKey;
          repoPath = fetchedRepos.${repoKey};
          skillSubpath = skillData.path;
          finalSkillName = if skillConf.name != null then skillConf.name else skillName;
        in
        lib.nameValuePair "${agentConf.path}/${finalSkillName}" {
          source = "${repoPath}/${skillSubpath}";
          recursive = true;
        }
      )
      targetedSkills;

  # Merge file definitions for all active agents
  homeFiles = lib.foldl'
    (acc: agentName:
      let
        agentConf = activeAgents.${agentName};
      in
      acc // (skillFilesForAgent agentName agentConf)
    )
    { }
    (builtins.attrNames activeAgents);
in
{
  options.modules.agentic-skills = {
    enable = mkEnableOption "declarative agent skills management";

    skills = mkOption {
      description = "Selected skills to enable. Represented as a flat attribute set.";
      default = { };
      # _file gives these dynamically generated options a real declaration
      # location; without it the module system reports "<unknown-file>",
      # which crashes nixd's option worker during completion.
      type = types.submodule {
        _file = toString ./default.nix;
        options = lib.mapAttrs
          (skillName: skillData: mkOption {
            default = { };
            description = "${skillData.description or "No description available"}${if skillData.repoUrl != "" then " (from ${skillData.repoUrl})" else ""}";
            type = types.submodule {
              _file = toString ./default.nix;
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable this skill.";
                };
                name = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Rename the skill when installing it (defaults to the skill's original name).";
                };
                agents = mkOption {
                  type = types.listOf (types.enum (builtins.attrNames agentTargets));
                  default = [ ];
                  description = "Override target agents for this skill. If empty ([]), installs to all active agents.";
                };
              };
            };
          })
          allSkills;
      };
    };

    agents = mkOption {
      description = "Target agent directory configurations. Available agents: ${lib.concatStringsSep ", " (builtins.attrNames agentTargets)}";
      default = { };
      type = types.submodule {
        _file = toString ./default.nix;
        options = lib.mapAttrs
          (name: defaultPath: mkOption {
            description = "Configuration for the ${name} agent.";
            default = { };
            type = types.submodule {
              _file = toString ./default.nix;
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable installing skills to the ${name} agent.";
                };
                path = mkOption {
                  type = types.str;
                  default = defaultPath;
                  description = "Path relative to the home directory to install skills to.";
                };
              };
            };
          })
          agentTargets;
      };
    };
  };

  config = mkIf (cfg.enable && (enabledSkills != { })) {
    home.file = homeFiles;
  };
}
