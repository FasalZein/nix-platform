# Shell secrets: export each NAME="value" line of the rendered env file that
# the secrets-render login agent writes (modules/darwin.nix). No value is in
# this file or the Nix store. Runs from /etc/zshenv, so every zsh, interactive
# or not, loads it. Without the file (before the first render) it does nothing.
# A name that is already set keeps its value (per-command, direnv or inherited
# overrides win; owner decision 2026-10-24). xtrace is off inside, so `zsh -x`
# cannot print values.
() {
  emulate -L zsh -o extended_glob -o no_xtrace
  local file=@shellEnvFile@ line name value out
  local -i i
  local -a match mbegin mend
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == (#b)([A-Za-z_][A-Za-z0-9_]#)=\"(*)\" ]] || continue
    name=$match[1] value=$match[2]
    [[ -v $name ]] && continue
    if [[ $value == *\\* ]]; then
      # Undo the escapes of `2password env resolve`: \\ \" \n \r. Nothing
      # else is expanded, so values keep $, backticks and quotes literally.
      out=
      for (( i = 1; i <= $#value; i++ )); do
        if [[ $value[i] == \\ ]] && (( i < $#value )); then
          (( i++ ))
          case $value[i] in
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            *) out+=$value[i] ;;
          esac
        else
          out+=$value[i]
        fi
      done
      value=$out
    fi
    export "$name=$value"
  done < $file
}
