#!/usr/bin/env bash
##############################################################################
# Скрипт для двухшагового удаления пользователей из PostgreSQL и MongoDB,
# с предварительной очисткой групповых связей (за исключением заданных групп).
#
# 1) ./users_check_delete_v03.sh prepare users.csv
#    (Входной файл users.csv содержит список email, которые НЕ нужно включать)
#
# 2) Проверьте получившийся CSV-файл.
#
# 3) ./users_check_delete_v03.sh delete users-delete_YYYYmmdd_HHMMSS.SCV
#
# При удалении сначала удаляются групповые связи (если они есть) и хвосты,
# затем удаляется сам пользователь.
##############################################################################

##############################################################################
# 1. ПЕРЕКЛЮЧАТЕЛИ (EXTERNAL / INTERNAL)
##############################################################################
POSTGRES_ON_SEPARATE_SERVER="False"  # False -> через kubectl exec
MONGO_ON_SEPARATE_SERVER="False"     # False -> через kubectl exec

##############################################################################
# 2. CONNECTION STRING (EXTERNAL ИЛИ INTERNAL)
##############################################################################
# --- PostgreSQL EXTERNAL (пример) ---
PG_CONN_EXTERNAL="postgresql://elma365:Password@192.168.1.21:5432/elma365?sslmode=disable"

# --- Mongo EXTERNAL (пример) ---
MONGO_CONN_EXTERNAL="mongodb://elma365:Password@192.168.1.22:27017/elma365?ssl=false"

# --- PostgreSQL INTERNAL ---
PG_CONN_INTERNAL="postgresql://postgres:pgpassword@postgres.elma365-dbs.svc.cluster.local:5432/elma365?sslmode=disable"

# --- Mongo INTERNAL ---
MONGO_CONN_INTERNAL="mongodb://elma365:mpassword@mongo.elma365-dbs.svc.cluster.local:27017/elma365?ssl=false"

# Названия коллекций
MONGO_COLLECTION_AUTH="elma_auth"
MONGO_COLLECTION_AUTH_EXT="elma_auth_external"

##############################################################################
# 3. ПЕРЕМЕННЫЕ: POD для POSTGRES и MONGO (при Internal)
##############################################################################
POSTGRES_POD="postgres-0"
MONGO_POD="mongo-0"
NAMESPACE="elma365-dbs"

##############################################################################
# 4. ПЕРЕМЕННЫЕ ДЛЯ ИСКЛЮЧЕНИЯ ГРУПП
##############################################################################
# Здесь можно задать список групп (по имени), которые НЕ будут учитываться при удалении.
# Для разделения нескольких групп используйте точку с запятой.
EXCLUDED_GROUPS="Все пользователи"

##############################################################################
# 5. ВЫБОР ФИНАЛЬНЫХ ПЕРЕМЕННЫХ И КОМАНД
##############################################################################
if [ "$POSTGRES_ON_SEPARATE_SERVER" = "True" ]; then
  PG_CONN="$PG_CONN_EXTERNAL"
  PG_MODE_TEXT="(External: $PG_CONN)"
  psql_cmd() {
    kubectl exec -i -n "$NAMESPACE" "$POSTGRES_POD" -- psql "$PG_CONN" "$@"
  }
else
  PG_CONN="$PG_CONN_INTERNAL"
  PG_MODE_TEXT="(Internal: kubectl exec $POSTGRES_POD -- psql $PG_CONN)"
  psql_cmd() {
    kubectl exec -i -n "$NAMESPACE" "$POSTGRES_POD" -- psql "$PG_CONN" "$@"
  }
fi

if [ "$MONGO_ON_SEPARATE_SERVER" = "True" ]; then
  MONGO_CONN="$MONGO_CONN_EXTERNAL"
  MONGO_MODE_TEXT="(External: $MONGO_CONN)"
  mongosh_cmd() {
    kubectl exec -i -n "$NAMESPACE" "$MONGO_POD" -- mongosh "$MONGO_CONN" "$@"
  }
else
  MONGO_CONN="$MONGO_CONN_INTERNAL"
  MONGO_MODE_TEXT="(Internal: kubectl exec $MONGO_POD -- mongosh $MONGO_CONN)"
  mongosh_cmd() {
    kubectl exec -i -n "$NAMESPACE" "$MONGO_POD" -- mongosh "$MONGO_CONN" "$@"
  }
fi

die() {
  echo >&2 "$@"
  exit 1
}

timestamp() {
  date +"%Y%m%d_%H%M%S"
}

##############################################################################
# 6. ПРОВЕРКА ПОДКЛЮЧЕНИЙ
##############################################################################
check_postgres_connection() {
  echo ">>> Проверяем подключение к PostgreSQL: $PG_MODE_TEXT"
  if ! psql_cmd -c "SELECT 1;" &>/dev/null; then
    die "!!! Не удалось подключиться к PostgreSQL."
  fi
  echo ">>> Успешно подключились к PostgreSQL."
}

check_mongo_connection() {
  echo ">>> Проверяем подключение к MongoDB: $MONGO_MODE_TEXT"
  local result
  result=$( mongosh_cmd --quiet --eval "db.runCommand({ping:1}).ok" )
  if [ "$result" != "1" ]; then
    die "!!! Не удалось подключиться к MongoDB. Результат ping: $result"
  fi
  echo ">>> Успешно подключились к MongoDB."
}

##############################################################################
# 7. РЕЖИМ: PREPARE
##############################################################################
prepare_mode() {
  local exclude_file="$1"  # Файл users.csv со списком email, которые НЕ включать

  if [ ! -f "$exclude_file" ]; then
    die "Файл $exclude_file не найден."
  fi

  # Считываем список исключённых email (users.csv – список для исключения 100%)
  declare -A EXCLUDE_EMAILS
  while IFS= read -r line; do
    local e
    e="$(echo "$line" | xargs)"  # удаляем лишние пробелы
    [ -n "$e" ] && EXCLUDE_EMAILS["$e"]=1
  done < "$exclude_file"

  check_postgres_connection
  check_mongo_connection

  local ts out_file
  ts=$(timestamp)
  out_file="users-delete_${ts}.SCV"
  # Заголовок CSV: добавляем столбец Groups (формат: group_id::group_name;...)
  echo "User,MongoAuth($MONGO_COLLECTION_AUTH),MongoAuthExt($MONGO_COLLECTION_AUTH_EXT),PG_ID(head.users),Groups" > "$out_file"

  # Читаем всех пользователей из PostgreSQL в массив (каждая строка имеет формат: GUID|email)
  mapfile -t pg_all_users_array < <( psql_cmd -t -A <<EOF
SELECT id || '|' || (body->>'email')
FROM head.users
ORDER BY (body->>'email');
EOF
  )

  echo "DEBUG: pg_all_users_array содержит ${#pg_all_users_array[@]} строк"
  echo "DEBUG: Список найденных пользователей:"
  for line in "${pg_all_users_array[@]}"; do
    echo "  $line"
  done

  # Подготавливаем строку с исключёнными группами для SQL.
  local excluded_groups_sql=""
  IFS=';' read -ra ex_groups <<< "$EXCLUDED_GROUPS"
  for grp in "${ex_groups[@]}"; do
    grp=$(echo "$grp" | xargs)
    if [ -n "$grp" ]; then
      if [ -z "$excluded_groups_sql" ]; then
        excluded_groups_sql="'$grp'"
      else
        excluded_groups_sql="$excluded_groups_sql,'$grp'"
      fi
    fi
  done

  # Перебираем все строки из массива
  for row in "${pg_all_users_array[@]}"; do
    # Если строка пустая — пропускаем
    [ -z "$row" ] && continue

    # Разбиваем строку по разделителю '|' на GUID и email
    local guid="${row%%|*}"
    local email="${row#*|}"

    # Если email входит в список исключённых (из файла users.csv), пропускаем его
    if [[ -n "${EXCLUDE_EMAILS["$email"]}" ]]; then
      continue
    fi

    # Получаем MongoID для коллекций (если есть)
    local MONGO_ID_AUTH=""
    MONGO_ID_AUTH=$( mongosh_cmd --quiet --eval "db.$MONGO_COLLECTION_AUTH.find({_id: \"$guid\"}).forEach(function(d){print(d._id);})" )

    local MONGO_ID_AUTH_EXT=""
    MONGO_ID_AUTH_EXT=$( mongosh_cmd --quiet --eval "db.$MONGO_COLLECTION_AUTH_EXT.find({_id: \"$guid\"}).forEach(function(d){print(d._id);})" )

    # Получаем список групп для пользователя (исключая группы из EXCLUDED_GROUPS).
    local pg_groups
    pg_groups=$( psql_cmd -t -A <<EOF
SELECT gl.super_id || '::' || (g.body::jsonb->>'__name')
FROM head.group_link gl
JOIN head.groups g ON gl.super_id = g.id
WHERE gl.object_id = '$guid'::uuid
  AND gl.object_type = 'user'
  AND (g.body::jsonb->>'__name') NOT IN ($excluded_groups_sql);
EOF
    )

    # Собираем группы в одну строку (если их несколько, разделяем точкой с запятой)
    local groups=""
    while IFS= read -r grp_line; do
      [ -z "$grp_line" ] && continue
      if [ -z "$groups" ]; then
        groups="$grp_line"
      else
        groups="$groups;$grp_line"
      fi
    done <<< "$pg_groups"

    # Записываем строку в CSV-файл (если групп нет, поле Groups будет пустым)
    echo "$email,$MONGO_ID_AUTH,$MONGO_ID_AUTH_EXT,$guid,\"$groups\"" >> "$out_file"
  done

  echo "Подготовлен список пользователей (без исключённых) в файл: $out_file"
  echo "Проверьте его прежде чем запускать удаление."
}

##############################################################################
# 8. РЕЖИМ: DELETE
##############################################################################
delete_mode() {
  local delete_file="$1"
  [ ! -f "$delete_file" ] && die "Файл $delete_file не найден."

  check_postgres_connection
  check_mongo_connection

  local log_file="delete_log_$(timestamp).log"
  echo "Лог удаления групповых связей" > "$log_file"

  local count_pg_deleted=0
  local count_mongo_auth_deleted=0
  local count_mongo_auth_ext_deleted=0

  local header_skipped=false
  while IFS= read -r line; do
    if [ "$header_skipped" = false ]; then
      header_skipped=true
      continue
    fi

    IFS=',' read -r user_field mongo_auth_id mongo_auth_ext_id pg_id groups_field <<< "$line"

    if [ -n "$groups_field" ]; then
      groups_field=$(echo "$groups_field" | sed 's/^"//;s/"$//')
      IFS=';' read -ra group_array <<< "$groups_field"
      for grp in "${group_array[@]}"; do
        IFS='::' read -r group_id group_name <<< "$grp"
        if [ -n "$group_id" ]; then
          psql_cmd -t -A <<EOF >/dev/null
DELETE FROM head.group_link
WHERE object_id = '$pg_id'
  AND object_type = 'user'
  AND super_id = '$group_id'
  AND super_type = 'group';
EOF
          psql_cmd -t -A <<EOF >/dev/null
WITH new_groupIds AS (
    SELECT jsonb_agg(id) AS new_array
    FROM jsonb_array_elements_text(
        (SELECT body->'groupIds' FROM head.users WHERE id = '$pg_id')
    ) AS id
    WHERE id <> '$group_id'
)
UPDATE head.users
SET body = jsonb_set(body, '{groupIds}', COALESCE((SELECT new_array FROM new_groupIds), '[]'::jsonb))
WHERE id = '$pg_id';
EOF
          psql_cmd -t -A <<EOF >/dev/null
WITH new_subOrgunitIds AS (
    SELECT jsonb_agg(id) AS new_array
    FROM jsonb_array_elements_text(
        (SELECT body->'subOrgunitIds' FROM head.groups WHERE id = '$group_id')
    ) AS id
    WHERE id <> '$pg_id'
)
UPDATE head.groups
SET body = jsonb_set(body, '{subOrgunitIds}', COALESCE((SELECT new_array FROM new_subOrgunitIds), '[]'::jsonb))
WHERE id = '$group_id';
EOF
          echo "$(date '+%Y-%m-%d %H:%M:%S'): User '$user_field' (PG_ID: $pg_id) удалён из группы '$group_name' (ID: $group_id)" >> "$log_file"
        fi
      done
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S'): User '$user_field' (PG_ID: $pg_id) не состоит ни в одной группе" >> "$log_file"
    fi

    if [ -n "$pg_id" ]; then
      psql_cmd -t -A <<EOF >/dev/null
DELETE FROM head.users WHERE id = '$pg_id';
EOF
      ((count_pg_deleted++))
    fi

    if [ -n "$mongo_auth_id" ]; then
      local del_auth
      del_auth=$( mongosh_cmd --quiet --eval "db.$MONGO_COLLECTION_AUTH.deleteOne({_id: \"$mongo_auth_id\"}).deletedCount" )
      if [ "$del_auth" = "1" ]; then
        ((count_mongo_auth_deleted++))
      fi
    fi

    if [ -n "$mongo_auth_ext_id" ]; then
      local del_auth_ext
      del_auth_ext=$( mongosh_cmd --quiet --eval "db.$MONGO_COLLECTION_AUTH_EXT.deleteOne({_id: \"$mongo_auth_ext_id\"}).deletedCount" )
      if [ "$del_auth_ext" = "1" ]; then
        ((count_mongo_auth_ext_deleted++))
      fi
    fi

  done < "$delete_file"

  echo "Удаление завершено."
  echo "В PostgreSQL удалено (пользователей): $count_pg_deleted"
  echo "В MongoDB ($MONGO_COLLECTION_AUTH) удалено (документов): $count_mongo_auth_deleted"
  echo "В MongoDB ($MONGO_COLLECTION_AUTH_EXT) удалено (документов): $count_mongo_auth_ext_deleted"
  echo "Детали удаления групповых связей записаны в файл: $log_file"
}

##############################################################################
# 9. ТОЧКА ВХОДА
##############################################################################
main() {
  local mode="$1"
  local file="$2"

  if [ -z "$mode" ] || [ -z "$file" ]; then
    echo "Использование:"
    echo "  $0 prepare <users.SCV>"
    echo "  $0 delete  <users-delete_YYYYmmdd_HHMMSS.SCV>"
    exit 1
  fi

  case "$mode" in
    prepare)
      prepare_mode "$file"
      ;;
    delete)
      delete_mode "$file"
      ;;
    *)
      die "Неизвестный режим: $mode"
      ;;
  esac
}

main "$@"
