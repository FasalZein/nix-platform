# Relative package paths resolve from ~/.pi/agent/settings.json, not this file.
{
  packages = [
    "git:github.com/edxeth/pi-gpt-config"
    "git:github.com/edxeth/pi-tasks"
    "git:github.com/edxeth/pi-better-skills"
    "git:github.com/edxeth/pi-subagents"
    "npm:pi-fancy-footer"
    "git:github.com/DietrichGebert/ponytail"
    "git:github.com/edxeth/pi-ralph-loop"
    "git:github.com/edxeth/pi-claude-auth"
    "../../Dev/AI/pi/extensions/pi-markdown-blocks"
    "npm:pi-grok-cli"
    "./packages/request-telemetry"
    "../../Dev/AI/pi/extensions/pi-ask"
  ];
  extensions = [
    "/Users/tothemoon/Dev/AI/pi/extensions/pi-ru"
    "/Users/tothemoon/Dev/AI/pi/extensions/pi-hub"
  ];
}
