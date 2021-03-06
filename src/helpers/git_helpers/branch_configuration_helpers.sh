#!/usr/bin/env bash


# Helper methods for managing the configuration of which branches
# are cut from which ones


# Returns the names of all branches that are registered in the hierarchy metadata,
# as an iterable list
function all_registered_branches {
  git config --get-regexp "^git-town-branch\..*\.parent$" | cut -d ' ' -f 1 | sed 's/^git-town-branch\.\(.*\)\.parent$/\1/' | sort | uniq
}


# Returns the names of all parent branches of the given branch,
# as a space delimited string, in hierarchical order,
function ancestor_branches {
  local branch_name=$1
  git config --get "git-town-branch.$branch_name.ancestors"
}


# Returns the names of all branches that have this branch as their immediate parent
function child_branches {
  local branch_name=$1
  git config --get-regexp "^git-town-branch\..*\.parent$" | grep "$branch_name$" | cut -d ' ' -f 1 | sed 's/^git-town-branch\.\(.*\)\.parent$/\1/' | sort
}


# Calculates the "ancestors" property for the given branch
# out of the existing "parent" properties
function compile_ancestor_branches {
  local branch_name=$1

  # re-create it from scratch
  local ancestors=''
  local current_branch="$branch_name"
  while [ "$current_branch" != "$MAIN_BRANCH_NAME" ] && [ -n "$current_branch" ]; do
    local parent=$(parent_branch "$current_branch")
    ancestors="$parent $ancestors"
    current_branch=$parent
  done

  # truncate the trailing space
  # shellcheck disable=SC2001
  echo "$ancestors" | sed 's/ $//'
}


# Removes all ancestor cache entries
function delete_all_ancestor_entries {
  git config --get-regexp "^git-town-branch.*ancestors$" | cut -d ' ' -f 1 | while read ancestor_entry; do
    git config --unset "$ancestor_entry"
  done
}


# Removes the "parent" entry for the given branch from the configuration
function delete_parent_entry {
  local branch_name=$1
  if [ "$(knows_parent_branch "$branch_name")" == "true" ]; then
    git config --unset "git-town-branch.$branch_name.parent"
  fi
  delete_ancestors_entry "$branch_name"
}


# Removes the "ancestors" entry from the configuration
function delete_ancestors_entry {
  local branch_name=$1
  if [ "$(knows_all_ancestor_branches "$branch_name")" == "true" ]; then
    git config --unset "git-town-branch.$branch_name.ancestors"
  fi
}


# Prints branches prefixed by a number and a colon with the main branch first
function echo_numbered_branches {
  local branches="$(local_branches_with_main_first | tr '\n' ' ')"
  local branch
  local number=1
  for branch in $branches; do
    output_style_bold
    printf "%3s: " "$number"
    output_style_reset
    echo "$branch"
    number=$(( number + 1 ))
  done
}

# Prints branches prefixed by a number and a colon with the order given alphabetically
function echo_numbered_branches_alpha_order {
  local branches="$(local_branches | tr '\n' ' ')"
  local branch
  local number=1
  for branch in $branches; do
    output_style_bold
    printf "%3s: " "$number"
    output_style_reset
    echo "$branch"
    number=$(( number + 1 ))
  done
}




# Prints the header for the prompt when asking for parent branches
function echo_parent_branch_header {
  echo
  echo "Feature branches can be branched directly off "
  echo "$MAIN_BRANCH_NAME or from other feature branches."
  echo
  echo "The former allows to develop and ship features completely independent of each other."
  echo "The latter allows to build on top of currently unshipped features."
  echo
  echo_numbered_branches
  echo
}


# Updates the child branches of the given branch to point to the other given branch
function echo_update_child_branches {
  local branch=$1
  local new_parent=$2

  child_branches "$branch" | while read branch_name; do
    echo delete_ancestors_entry "$branch_name"
    echo store_parent_branch "$branch_name" "$new_parent"
  done
}


# Makes sure that we know all the parent branches
# Asks the user if necessary
function ensure_knows_parent_branches {
  local branches=$1 # space separated list of branches

  local ancestors
  local branch
  local child
  local header_shown=false
  local numerical_regex='^[0-9]+$'
  local parent
  local user_input

  for branch in $branches; do
    child=$branch
    if [ "$(knows_all_ancestor_branches "$child")" = true ]; then
      continue
    fi
    if [ "$(is_perennial_branch "$child")" = true ]; then
      continue
    fi

    while [ "$child" != "$MAIN_BRANCH_NAME" ]; do
      if [ "$(knows_parent_branch "$child")" = true ]; then
        parent=$(parent_branch "$child")
      else
        if [ "$header_shown" = false ]; then
          echo_parent_branch_header
          header_shown=true
        fi

        parent=""
        while [ -z "$parent" ]; do
          echo -n "Please specify the parent branch of $(echo_inline_cyan_bold "$child") by name or number (default: $MAIN_BRANCH_NAME): "
          read user_input
          if [[ $user_input =~ $numerical_regex ]] ; then
            # user entered a number here
            parent="$(get_numbered_branch "$user_input")"
            if [ -z "$parent" ]; then
              echo_error_header
              echo_error "Invalid branch number"
            fi
          elif [ -z "$user_input" ]; then
            # user entered nothing
            parent=$MAIN_BRANCH_NAME
          else
            if [ "$(has_branch "$user_input")" == true ]; then
              parent=$user_input
            else
              echo_error_header
              echo_error "Branch '$user_input' doesn't exist"
            fi
          fi
          if [ "$child" = "$parent" ]; then
            echo_error_header
            echo_error "'$child' cannot be the parent of itself"
            parent=''
          elif [ "$(has_ancestor_branch "$parent" "$child")" = true ]; then
            echo_error_header
            echo_error "Nested branch loop detected: '$child' is an ancestor of '$parent'"
            parent=''
          fi
        done
        store_parent_branch "$child" "$parent"
      fi
      child=$parent
    done
    ancestors=$(compile_ancestor_branches "$branch")
    store_ancestor_branches "$branch" "$ancestors"
  done

  if [ "$header_shown" = true ]; then
    echo
  fi
}


# Returns the branch name for the number shown in print_numbered_branches
# when printed with the main branch first
function get_numbered_branch {
  local number=$1
  local_branches_with_main_first | sed -n "${number}p"
}

# Returns the branch name for the number shown in print_numbered_branches
# when printed in alpha order
function get_numbered_branch_alpha_order {
  local number=$1
  local_branches | sed -n "${number}p"
}


# Returns whether the first branch has the second branch as an ancestor
function has_ancestor_branch {
  local branch_name_1=$1
  local branch_name_2=$2

  if [ "$(compile_ancestor_branches "$branch_name_1" | grep -c "\b$branch_name_2\b")" = 0 ]; then
    echo false
  else
    echo true
  fi
}


# Returns whether the given branch has child branches
function has_child_branches {
  local branch_name=$1

  if [ "$(child_branches "$branch_name")" == "" ]; then
    echo false
  else
    echo true
  fi
}


# Returns whether we know the parent branch for the given branch
function knows_parent_branch {
  local branch_name=$1
  if [ -z "$(parent_branch "$branch_name")" ]; then
    echo false
  else
    echo true
  fi
}


# Returns whether we know the parent branches for the given branch
function knows_all_ancestor_branches {
  local branch_name=$1
  if [ -z "$(ancestor_branches "$branch_name")" ]; then
    echo false
  else
    echo true
  fi
}


# Returns the names of all parent branches, in hierarchical order
function parent_branch {
  local branch_name=$1
  git config --get "git-town-branch.$branch_name.parent"
}


# Stores the ancestors for the given branch
function store_ancestor_branches {
  local branch=$1
  local ancestor_branches=$2
  git config "git-town-branch.$branch.ancestors" "$ancestor_branches"
}


# Stores the given branch as the parent branch for the given branch
function store_parent_branch {
  local branch=$1
  local parent_branch=$2
  if [ -n "$parent_branch" ]; then
    git config "git-town-branch.$branch.parent" "$parent_branch"
  else
    delete_parent_entry "$branch"
  fi
}


function undo_steps_for_delete_parent_entry {
  local branch_name=$1

  if [ "$(knows_parent_branch "$branch_name")" == "true" ]; then
    echo "store_parent_branch $branch_name $(parent_branch "$branch_name")"
  fi
}


function undo_steps_for_store_parent_branch {
  local branch=$1

  local old_parent_branch ; old_parent_branch=$(parent_branch "$branch")
  echo "store_parent_branch $branch $old_parent_branch"
}
