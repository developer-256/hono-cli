#! /bin/bash

# Input validation
if [ -z "$1" ]; then
  echo "❌ Error: Please provide a module name"
  echo "Usage: $0 <module_name>"
  exit 1
fi

input=$1
resource_name=$input

# Validate resource name (camelCase: starts with lowercase, then letters/numbers)
if [[ ! "$resource_name" =~ ^[a-z][a-zA-Z0-9]*$ ]]; then
  echo "❌ Error: Module name must be in camelCase (start with lowercase letter, then letters/numbers only)"
  exit 1
fi

routes=("DELETE" "GET_ONE" "GET" "PATCH" "POST")

# Navigate to src/modules directory
if ! cd src/modules 2>/dev/null; then
  echo "❌ Directory src/modules does not exist"
  exit 1
fi

if [ -d "${resource_name}" ]; then
  echo "❌ Error: Module ${resource_name} already exists"
  exit 1
fi

# Create module directory structure with cleanup on failure
cleanup() {
  if [ -d "${resource_name}" ]; then
    echo "🧹 Cleaning up incomplete module directory..."
    rm -rf "${resource_name}"
  fi
}

trap cleanup EXIT

mkdir "$resource_name" || { echo "❌ Failed to create module directory"; exit 1; }
cd "$resource_name" || { echo "❌ Failed to enter module directory"; exit 1; }

mkdir controller service entity routes || { echo "❌ Failed to create subdirectories"; exit 1; }

cd controller
touch index.ts
cat >>index.ts <<EOF
import { createRouter } from "@/lib/config/create-router.config";
EOF

for route in ${routes[@]}; do
  echo "import { ${route}_DTO, ${route}_Handler } from \"../routes/${route}\";" >>index.ts
done

cat >>index.ts <<EOF

export const ${resource_name}Controller = createRouter()
EOF

# Add .openapi() calls with proper formatting
route_count=${#routes[@]}
for i in "${!routes[@]}"; do
  route="${routes[$i]}"
  if [ $i -eq $((route_count - 1)) ]; then
    # Last route gets semicolon
    echo "  .openapi(${route}_DTO, ${route}_Handler);" >>index.ts
  else
    # Other routes without semicolon
    echo "  .openapi(${route}_DTO, ${route}_Handler)" >>index.ts
  fi
done

cd ../entity
touch index.ts
cat >>index.ts <<EOF
import { index, serial } from "drizzle-orm/pg-core";
import { relations } from "drizzle-orm";
import type { InferSelectModel } from "drizzle-orm";
import { createTable } from "@/db/extras/db.utils";

export const ${resource_name} = createTable(
  "${resource_name}",
  {
    id: serial("id").primaryKey(),
  },
  (table) => [index().on(table.id)]
);

export const ${resource_name}Relations = relations(${resource_name}, ({ many, one }) => ({}));

export type ${resource_name^}TableType = InferSelectModel<typeof ${resource_name}>;

EOF

# Create service template
# cd ../service
# touch index.ts
# cat >>index.ts <<EOF
# import { db } from "@/db";
# import { eq } from "drizzle-orm";
# import { ${resource_name} } from "../entity";

# export class ${resource_name^}Service {
#   static async getAll() {
#     return await db.select().from(${resource_name});
#   }

#   static async getById(id: number) {
#     return await db.select().from(${resource_name}).where(eq(${resource_name}.id, id));
#   }

#   static async create(data: Omit<typeof ${resource_name}.\$inferInsert, 'id'>) {
#     return await db.insert(${resource_name}).values(data).returning();
#   }

#   static async update(id: number, data: Partial<typeof ${resource_name}.\$inferInsert>) {
#     return await db.update(${resource_name}).set(data).where(eq(${resource_name}.id, id)).returning();
#   }

#   static async delete(id: number) {
#     return await db.delete(${resource_name}).where(eq(${resource_name}.id, id)).returning();
#   }
# }
# EOF

cd ../routes

for route in ${routes[@]}; do
  touch "${route}.ts"

  case "$route" in
    "GET_ONE"|"GET_PROFILE"|"GET_"*)
      method="get"
      ;;
    "POST_"*|"POST")
      method="post"
      ;;
    "PUT_"*|"PUT")
      method="put"
      ;;
    "PATCH_"*|"PATCH")
      method="patch"
      ;;
    "DELETE_"*|"DELETE")
      method="delete"
      ;;
    *)
      # Default case: convert to lowercase
      method=${route,,}
      # If it contains underscores, extract the first part as method
      if [[ "$route" == *"_"* ]]; then
        method=$(echo "$route" | cut -d'_' -f1 | tr '[:upper:]' '[:lower:]')
      fi
      ;;
  esac

  cat >>"${route}.ts" <<EOF
import { OKResponse } from "@/lib/constants/open-api.constants";
import { createRoute, RouteHandler } from "@hono/zod-openapi";
import { moduleTags } from "../../module.tags";

export const ${route}_DTO = createRoute({
  path: "",
  method: "${method}",
  tags: moduleTags.${resource_name},
  request: {},
  responses: {
    ...OKResponse,
  },
});

export const ${route}_Handler: RouteHandler<typeof ${route}_DTO> = async (c) => {
  return c.json({ success: true });
};

EOF
done

# Create or update module tags file
cd ../../../modules
TAGS_FILE="module.tags.ts"

if [ ! -f "$TAGS_FILE" ]; then
  # Create tags file if it doesn't exist
  cat >"$TAGS_FILE" <<EOF
export const moduleTags = {
  ${resource_name}: ["${resource_name^}"],
};
EOF
  echo "✅ Created ${TAGS_FILE} with ${resource_name} tag"
else
  # Add new tag to existing file
  # Check if the resource tag already exists
  if ! grep -q "${resource_name}:" "$TAGS_FILE"; then
    # Add new tag before the closing brace
    sed -i "/^};/i\\  ${resource_name}: [\"${resource_name^}\"]," "$TAGS_FILE"
    echo "✅ Added ${resource_name} tag to ${TAGS_FILE}"
  fi
fi

# Update src/index.ts with new controller
cd ../../
INDEX_FILE="index.ts"

# Add import statement after the last import
IMPORT_LINE="import { ${resource_name}Controller } from \"./modules/${resource_name}/controller\";"
LAST_IMPORT_LINE=$(grep -n "^import" "$INDEX_FILE" | tail -1 | cut -d: -f1)
sed -i "${LAST_IMPORT_LINE}a\\${IMPORT_LINE}" "$INDEX_FILE"

# Add controller to the controllers array
# Find the controllers array specifically and handle both empty and non-empty arrays
CONTROLLERS_START=$(grep -n "const controllers = \[" "$INDEX_FILE" | cut -d: -f1)
CONTROLLERS_END=$(tail -n +$CONTROLLERS_START "$INDEX_FILE" | grep -n "^];" | head -1 | cut -d: -f1)
CONTROLLERS_END_LINE=$((CONTROLLERS_START + CONTROLLERS_END - 1))

# Check if array is empty (controllers = []; on same line or next line)
if grep -A1 "const controllers = \[" "$INDEX_FILE" | grep -q "^];"; then
  # Empty array - replace the empty array with array containing the controller
  sed -i "s/const controllers = \[\];/const controllers = [\n  ${resource_name}Controller,\n];/" "$INDEX_FILE"
else
  # Non-empty array - add controller before closing bracket
  PREV_LINE=$((CONTROLLERS_END_LINE - 1))
  sed -i "${PREV_LINE}a\\  ${resource_name}Controller," "$INDEX_FILE"
fi

# Disable cleanup trap on successful completion
trap - EXIT
echo "✅ Module '${resource_name}' created successfully!"
