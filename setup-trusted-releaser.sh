#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Constants
GITHUB_ACTIONS_INTEGRATION_ID=15368  # GitHub Actions App ID

# Default values
ADD_REVIEWER=false
REVIEWER_USERS=""
DRY_RUN=false
SKIP_CONFIRM=false
REQUIRED_APPROVALS=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --add-reviewer)
            ADD_REVIEWER=true
            shift
            # Check if next argument exists and doesn't start with --
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                REVIEWER_USERS="$1"
                shift
            fi
            ;;
        --required-approvals)
            shift
            if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                REQUIRED_APPROVALS="$1"
                shift
            else
                echo "Error: --required-approvals requires a number"
                exit 1
            fi
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --add-reviewer [USERS]     Add required reviewers for the release environment"
            echo "                             USERS: Comma-separated GitHub usernames (default: yourself)"
            echo "                             Example: --add-reviewer user1,user2,user3"
            echo "  --required-approvals NUM   Number of required PR approvals (default: 0)"
            echo "                             Example: --required-approvals 1"
            echo "  --dry-run                  Show what would be done without making changes"
            echo "  -y, --yes                  Skip confirmation prompt"
            echo "  -h, --help                 Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Get repository information
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
CURRENT_USER=$(gh api user -q .login)
CURRENT_USER_ID=$(gh api user -q .id)
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

# Function to check if environment exists
check_environment_exists() {
    local env_name=$1
    gh api "/repos/$OWNER/$REPO_NAME/environments/$env_name" >/dev/null 2>&1
}

# Function to check if ruleset exists
check_ruleset_exists() {
    local ruleset_name=$1
    local result=$(gh api "/repos/$OWNER/$REPO_NAME/rulesets" -q ".[] | select(.name == \"$ruleset_name\") | .name" 2>/dev/null)
    [ -n "$result" ]
}

# Function to check if default branch is already protected by any ruleset
check_default_branch_protected() {
    local rulesets=$(gh api "/repos/$OWNER/$REPO_NAME/rulesets" 2>/dev/null)
    
    # Check each ruleset to see if it targets the default branch
    while IFS= read -r ruleset_id; do
        if [ -n "$ruleset_id" ] && [ "$ruleset_id" != "null" ]; then
            local detailed_ruleset=$(gh api "/repos/$OWNER/$REPO_NAME/rulesets/$ruleset_id" 2>/dev/null)
            local name=$(echo "$detailed_ruleset" | jq -r '.name')
            local target=$(echo "$detailed_ruleset" | jq -r '.target')
            
            if [ "$target" = "branch" ]; then
                local includes=$(echo "$detailed_ruleset" | jq -r '.conditions.ref_name.include[]?' 2>/dev/null)
                if [ -n "$includes" ]; then
                    while IFS= read -r include; do
                        if [ "$include" = "~DEFAULT_BRANCH" ] || [ "$include" = "$DEFAULT_BRANCH" ] || [ "$include" = "refs/heads/$DEFAULT_BRANCH" ]; then
                            echo "protected:$name"
                            return 0
                        fi
                    done <<< "$includes"
                fi
            fi
        fi
    done <<< "$(echo "$rulesets" | jq -r '.[].id')"
}

# Function to check for existing tag protection rulesets
check_tag_protection_exists() {
    local rulesets=$(gh api "/repos/$OWNER/$REPO_NAME/rulesets" 2>/dev/null)
    local existing_tag_rulesets=""
    
    while IFS= read -r ruleset; do
        if [ -n "$ruleset" ]; then
            local name=$(echo "$ruleset" | jq -r '.name')
            local target=$(echo "$ruleset" | jq -r '.target')
            
            if [ "$target" = "tag" ] && [ "$name" != "Protect all tags" ]; then
                if [ -z "$existing_tag_rulesets" ]; then
                    existing_tag_rulesets="$name"
                else
                    existing_tag_rulesets="$existing_tag_rulesets, $name"
                fi
            fi
        fi
    done <<< "$(echo "$rulesets" | jq -c '.[]?')"
    
    echo "$existing_tag_rulesets"
}

echo "Setting up GitHub repository: $REPO"
echo "Current user: $CURRENT_USER"
echo "Default branch: $DEFAULT_BRANCH"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE: No changes will be made${NC}"
fi
echo ""

# Function to check if label exists
check_label_exists() {
    local label_name=$1
    gh api "/repos/$OWNER/$REPO_NAME/labels/$label_name" >/dev/null 2>&1
}

# Function to create bump labels
create_bump_labels() {
    local labels=(
        "bump:major|#d73a49|For breaking changes that require a major version bump"
        "bump:minor|#a2eeef|For new features that require a minor version bump"
        "bump:patch|#7057ff|For bug fixes that require a patch version bump"
    )
    
    for label_info in "${labels[@]}"; do
        IFS='|' read -r name color description <<< "$label_info"
        
        if check_label_exists "$name"; then
            echo "Label '$name' already exists, skipping..."
        else
            if [ "$DRY_RUN" = true ]; then
                echo -e "${YELLOW}[DRY RUN] Would create label: $name${NC}"
            else
                local label_payload=$(cat <<EOF
{
  "name": "$name",
  "color": "${color#'#'}",
  "description": "$description"
}
EOF
                )
                
                if gh api \
                    --method POST \
                    -H "Accept: application/vnd.github+json" \
                    "/repos/$OWNER/$REPO_NAME/labels" \
                    --input - <<< "$label_payload" >/dev/null; then
                    echo -e "${GREEN}✓ Label '$name' created successfully${NC}"
                else
                    echo -e "${RED}✗ Failed to create label '$name'${NC}"
                fi
            fi
        fi
    done
}

# Function to show detailed confirmation
show_detailed_confirmation() {
    echo -e "${YELLOW}=== DETAILED EXECUTION PLAN ===${NC}"
    echo ""
    
    # Check what actually needs to be done
    branch_exists=$(check_ruleset_exists "Protect main branch" && echo "true" || echo "false")
    env_exists=$(check_environment_exists "release" && echo "true" || echo "false")
    tag_exists=$(check_ruleset_exists "Protect all tags" && echo "true" || echo "false")
    
    # Check bump labels
    major_label_exists=$(check_label_exists "bump:major" && echo "true" || echo "false")
    minor_label_exists=$(check_label_exists "bump:minor" && echo "true" || echo "false")
    patch_label_exists=$(check_label_exists "bump:patch" && echo "true" || echo "false")
    
    # Check for existing branch protection
    branch_protection_result=$(check_default_branch_protected)
    existing_branch_protection=""
    if echo "$branch_protection_result" | grep -q "protected:"; then
        existing_branch_protection=$(echo "$branch_protection_result" | grep "protected:" | cut -d':' -f2)
    fi
    
    # Check for existing tag protection
    existing_tag_protection=$(check_tag_protection_exists)
    
    echo -e "${YELLOW}[1/4] Branch Protection Ruleset${NC}"
    if [ "$branch_exists" = "true" ]; then
        echo "  Status: Already exists, will be skipped"
    elif [ -n "$existing_branch_protection" ]; then
        echo "  Status: Default branch ($DEFAULT_BRANCH) already protected by ruleset: '$existing_branch_protection'"
        echo "  Action: Will be skipped to avoid conflicts"
    else
        echo "  Status: Will be created"
        echo "  Rules: Restrict deletions, Require signed commits, Require PR approval ($REQUIRED_APPROVALS), Block force pushes"
        echo "  Target: Default branch ($DEFAULT_BRANCH)"
        echo "  Command: gh api --method POST /repos/$OWNER/$REPO_NAME/rulesets"
    fi
    echo ""
    
    echo -e "${YELLOW}[2/4] Release Environment${NC}"
    if [ "$env_exists" = "true" ]; then
        echo "  Status: Already exists, will be skipped"
    else
        echo "  Status: Will be created"
        echo "  Deployment branches: main only"
        if [ "$ADD_REVIEWER" = true ]; then
            echo "  Required reviewers: ${REVIEWER_USERS:-$CURRENT_USER}"
        else
            echo "  Required reviewers: None"
        fi
        echo "  Commands:"
        echo "    - gh api --method PUT /repos/$OWNER/$REPO_NAME/environments/release"
        echo "    - gh api --method POST /repos/$OWNER/$REPO_NAME/environments/release/deployment-branch-policies"
    fi
    echo ""
    
    echo -e "${YELLOW}[3/4] Tag Protection Ruleset${NC}"
    if [ "$tag_exists" = "true" ]; then
        echo "  Status: Already exists, will be skipped"
    else
        echo "  Status: Will be created"
        echo "  Rules: Restrict deletions, Require deployment to 'release', Require 'release-approval' status check"
        echo "  Target: All tags (*)"
        echo "  Status check source: GitHub Actions (ID: $GITHUB_ACTIONS_INTEGRATION_ID)"
        echo "  Command: gh api --method POST /repos/$OWNER/$REPO_NAME/rulesets"
        if [ -n "$existing_tag_protection" ]; then
            echo -e "  ${YELLOW}Warning: Existing tag protection rulesets found: $existing_tag_protection${NC}"
            echo -e "  ${YELLOW}This may create conflicting rules${NC}"
        fi
    fi
    echo ""
    
    echo -e "${YELLOW}[4/4] Bump Labels${NC}"
    labels_to_create=()
    if [ "$major_label_exists" = "false" ]; then labels_to_create+=("bump:major"); fi
    if [ "$minor_label_exists" = "false" ]; then labels_to_create+=("bump:minor"); fi
    if [ "$patch_label_exists" = "false" ]; then labels_to_create+=("bump:patch"); fi
    
    if [ ${#labels_to_create[@]} -eq 0 ]; then
        echo "  Status: All bump labels already exist, will be skipped"
    else
        echo "  Status: Will create labels: ${labels_to_create[*]}"
        echo "  Labels:"
        echo "    - bump:major: For breaking changes (red)"
        echo "    - bump:minor: For new features (light blue)" 
        echo "    - bump:patch: For bug fixes (purple)"
        echo "  Command: gh api --method POST /repos/$OWNER/$REPO_NAME/labels"
    fi
    echo ""
    
    # Summary of actual changes
    changes_count=0
    if [ "$branch_exists" = "false" ] && [ -z "$existing_branch_protection" ]; then ((changes_count++)); fi
    if [ "$env_exists" = "false" ]; then ((changes_count++)); fi
    if [ "$tag_exists" = "false" ]; then ((changes_count++)); fi
    if [ ${#labels_to_create[@]} -gt 0 ]; then ((changes_count++)); fi
    
    echo -e "${YELLOW}=== SUMMARY ===${NC}"
    if [ $changes_count -eq 0 ]; then
        echo "No changes will be made (all resources already exist)"
        return 0
    else
        echo "Total changes to be made: $changes_count"
        echo ""
        read -p "Do you want to proceed with these changes? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            exit 0
        fi
    fi
    echo ""
}

# Show confirmation if needed
if [ "$SKIP_CONFIRM" = false ] && [ "$DRY_RUN" = false ]; then
    show_detailed_confirmation
fi

# 1. Create ruleset for main branch protection
echo -e "${YELLOW}[1/4] Creating ruleset for main branch protection...${NC}"

branch_ruleset_payload=$(cat <<EOF
{
  "name": "Protect main branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "deletion"
    },
    {
      "type": "required_signatures"
    },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": $REQUIRED_APPROVALS,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "non_fast_forward"
    }
  ]
}
EOF
)

# Check for existing protection before creating
branch_protection_result=$(check_default_branch_protected)
existing_branch_protection=""
if echo "$branch_protection_result" | grep -q "protected:"; then
    existing_branch_protection=$(echo "$branch_protection_result" | grep "protected:" | cut -d':' -f2)
fi

if check_ruleset_exists "Protect main branch"; then
    echo "Ruleset 'Protect main branch' already exists, skipping..."
elif [ -n "$existing_branch_protection" ]; then
    echo -e "${YELLOW}Default branch ($DEFAULT_BRANCH) already protected by ruleset: '$existing_branch_protection', skipping...${NC}"
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would create branch protection ruleset${NC}"
    else
        if gh api \
            --method POST \
            -H "Accept: application/vnd.github+json" \
            "/repos/$OWNER/$REPO_NAME/rulesets" \
            --input - <<< "$branch_ruleset_payload" >/dev/null; then
            echo -e "${GREEN}✓ Branch protection ruleset created successfully${NC}"
        else
            echo -e "${RED}✗ Failed to create branch protection ruleset${NC}"
            exit 1
        fi
    fi
fi

# 2. Create release environment
echo -e "${YELLOW}[2/4] Creating 'release' environment...${NC}"

# Create environment payload
if [ "$ADD_REVIEWER" = true ]; then
    # If no users specified, use current user
    if [ -z "$REVIEWER_USERS" ]; then
        REVIEWER_USERS="$CURRENT_USER"
    fi
    
    # Build reviewers JSON array
    reviewers_json=""
    IFS=',' read -ra USERS <<< "$REVIEWER_USERS"
    for user in "${USERS[@]}"; do
        # Trim whitespace
        user=$(echo "$user" | xargs)
        # Get user ID
        user_id=$(gh api "/users/$user" -q .id 2>/dev/null)
        if [ -n "$user_id" ]; then
            if [ -n "$reviewers_json" ]; then
                reviewers_json+=","
            fi
            reviewers_json+=$(cat <<EOF

    {
      "type": "User",
      "id": $user_id
    }
EOF
            )
            echo "Adding reviewer: $user (ID: $user_id)"
        else
            echo -e "${YELLOW}Warning: User '$user' not found, skipping${NC}"
        fi
    done
    
    env_payload=$(cat <<EOF
{
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  },
  "reviewers": [$reviewers_json
  ]
}
EOF
    )
else
    env_payload=$(cat <<EOF
{
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF
    )
fi

# Create or update the environment
if check_environment_exists "release"; then
    echo "Environment 'release' already exists, skipping..."
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would create environment 'release'${NC}"
        if [ "$ADD_REVIEWER" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would add reviewers: ${REVIEWER_USERS:-$CURRENT_USER}${NC}"
        fi
    else
        echo "Creating new environment 'release'..."
        
        if gh api \
            --method PUT \
            -H "Accept: application/vnd.github+json" \
            "/repos/$OWNER/$REPO_NAME/environments/release" \
            --input - <<< "$env_payload" >/dev/null; then
            
            # Add deployment branch policy for main branch
            branch_policy_payload=$(cat <<EOF
{
  "name": "main",
  "type": "branch"
}
EOF
            )
            
            if gh api \
                --method POST \
                -H "Accept: application/vnd.github+json" \
                "/repos/$OWNER/$REPO_NAME/environments/release/deployment-branch-policies" \
                --input - <<< "$branch_policy_payload" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Release environment created successfully${NC}"
            else
                echo -e "${YELLOW}! Deployment branch policy might already exist or failed to add${NC}"
            fi
        else
            echo -e "${RED}✗ Failed to create release environment${NC}"
            exit 1
        fi
    fi
fi

# 3. Create ruleset for tag protection
echo -e "${YELLOW}[3/4] Creating ruleset for tag protection...${NC}"

tag_ruleset_payload=$(cat <<EOF
{
  "name": "Protect all tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~ALL"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "deletion"
    },
    {
      "type": "required_deployments",
      "parameters": {
        "required_deployment_environments": ["release"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": [
          {
            "context": "release-approval",
            "integration_id": $GITHUB_ACTIONS_INTEGRATION_ID
          }
        ],
        "strict_required_status_checks_policy": false
      }
    }
  ]
}
EOF
)

# Check for existing tag protection
existing_tag_protection=$(check_tag_protection_exists)
if [ -n "$existing_tag_protection" ]; then
    echo -e "${YELLOW}Warning: Existing tag protection rulesets found: $existing_tag_protection${NC}"
fi

if check_ruleset_exists "Protect all tags"; then
    echo "Ruleset 'Protect all tags' already exists, skipping..."
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would create tag protection ruleset${NC}"
        if [ -n "$existing_tag_protection" ]; then
            echo -e "${YELLOW}[DRY RUN] Warning: This may conflict with existing tag rulesets${NC}"
        fi
    else
        if gh api \
            --method POST \
            -H "Accept: application/vnd.github+json" \
            "/repos/$OWNER/$REPO_NAME/rulesets" \
            --input - <<< "$tag_ruleset_payload" >/dev/null; then
            echo -e "${GREEN}✓ Tag protection ruleset created successfully${NC}"
        else
            echo -e "${RED}✗ Failed to create tag protection ruleset${NC}"
            echo -e "${YELLOW}Note: Some ruleset features may require GitHub Enterprise${NC}"
        fi
    fi
fi

# 4. Create bump labels
echo -e "${YELLOW}[4/4] Creating bump labels...${NC}"
create_bump_labels

echo ""
echo -e "${GREEN}Repository setup completed!${NC}"
echo ""
echo "Summary of changes:"
echo "- Branch ruleset: Created for main branch with deletion restriction, signed commits, PR requirement ($REQUIRED_APPROVALS approvals), and no force pushes"
echo "- Release environment: Created with main branch deployment policy"
if [ "$ADD_REVIEWER" = true ]; then
    echo "  - Required reviewers: $REVIEWER_USERS"
fi
echo "- Tag ruleset: Created for all tags with deletion restriction, deployment requirement, and status check requirement"
echo "- Bump labels: Created bump:major, bump:minor, bump:patch labels for version management"
echo ""
echo "You can view and manage the rulesets at:"
echo "https://github.com/$REPO/settings/rules"