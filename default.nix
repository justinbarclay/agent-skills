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

  # Options shared by both catalog skills and custom skills for controlling
  # naming and agent targeting. `enable` and (for custom skills) `source` are
  # added separately by each submodule since their defaults/presence differ.
  skillTargetingOptions = {
    name = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Rename the skill directory when installing (defaults to the attribute name).";
    };
    agents = mkOption {
      type = types.listOf (types.enum (builtins.attrNames agentTargets));
      default = [ ];
      description = "Override target agents for this skill. If empty ([]), installs to all active agents.";
    };
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
  enabledCustomSkills = lib.filterAttrs (name: skillConf: skillConf.enable) cfg.customSkills;

  # Normalize catalog skills and custom skills into a single common shape so
  # they can be targeted, installed, and collision-checked by one pipeline
  # instead of two parallel ones.
  normalizedCatalogSkills = lib.mapAttrsToList
    (skillName: skillConf:
      let
        skillData = allSkills.${skillName} or (throw "Skill '${skillName}' not found in skills-catalog.json");
        repoPath = fetchedRepos.${skillData.repoKey};
      in
      {
        finalName = if skillConf.name != null then skillConf.name else skillName;
        source = "${repoPath}/${skillData.path}";
        agents = skillConf.agents;
        origin = "catalog skill '${skillName}'";
      }
    )
    enabledSkills;

  normalizedCustomSkills = lib.mapAttrsToList
    (skillName: skillConf: {
      finalName = if skillConf.name != null then skillConf.name else skillName;
      source = skillConf.source;
      agents = skillConf.agents;
      origin = "custom skill '${skillName}'";
    })
    enabledCustomSkills;

  allNormalizedSkills = normalizedCatalogSkills ++ normalizedCustomSkills;

  # Whether a skill's agent targeting includes the given agent
  targetsAgent = agentName: skill:
    skill.agents == [ ] || lib.elem agentName skill.agents;

  # Build the file configurations for a single agent
  skillFilesForAgent = agentName: agentConf:
    let
      targeted = lib.filter (targetsAgent agentName) allNormalizedSkills;

      # Group by final install name so collisions (from catalog skills,
      # custom skills, or a mix of both) are all caught the same way.
      grouped = lib.foldl'
        (acc: skill: acc // { ${skill.finalName} = (acc.${skill.finalName} or [ ]) ++ [ skill ]; })
        { }
        targeted;

      collisions = lib.filterAttrs (finalName: skills: lib.length skills > 1) grouped;
    in
    if collisions != { }
    then
      throw "agentic-skills: skill name collision(s) for agent '${agentName}': ${
      lib.concatStringsSep "; " (lib.mapAttrsToList
        (finalName: skills: "'${finalName}' (${lib.concatStringsSep ", " (map (s: s.origin) skills)})")
        collisions)
    }. Rename one of the conflicting skills via its 'name' option."
    else
      lib.mapAttrs'
        (finalName: skills:
          lib.nameValuePair "${agentConf.path}/${finalName}" {
            source = (lib.head skills).source;
            recursive = true;
          }
        )
        grouped;

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
              options = skillTargetingOptions // {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable this skill.";
                };
              };
            };
          })
          allSkills;
      };
    };

    customSkills = mkOption {
      description = "Custom user-defined skills from local directory paths or external sources.";
      default = { };
      type = types.attrsOf (types.submodule {
        _file = toString ./default.nix;
        options = skillTargetingOptions // {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable this custom skill.";
          };
          source = mkOption {
            type = types.path;
            description = "Path to directory containing the skill (e.g. ./skills/my-skill).";
          };
        };
      });
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

  config = mkIf (cfg.enable && (enabledSkills != { } || enabledCustomSkills != { })) {
    home.file = homeFiles;
  };
}
