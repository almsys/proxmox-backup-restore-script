#!/bin/bash

show_help() {
    cat << EOF
Использование: $0 ACTION START END [DESCRIPTION] [STORAGE] [BACKUP_ID]

ACTIONS:
  create      - Создать снапшот для ВМ в диапазоне
  rollback    - Откатить ВМ к снапшоту с указанным описанием
  delete      - Удалить снапшоты с указанным описанием
  backup      - Создать бэкап ВМ в указанное хранилище
  restore     - Восстановить ВМ из бэкапа
  list        - Показать все ВМ в диапазоне и их снапшоты
  listbackup  - Показать доступные бэкапы в хранилище
  Destroy     - Удалить все ВМ в диапазоне (требует подтверждения)

Параметры:
  ACTION      - Обязательный. Действие для выполнения
  START       - Обязательный. Начальный ID ВМ
  END         - Обязательный. Конечный ID ВМ
  DESCRIPTION - Описание снапшота/бэкапа (для create/rollback/delete/backup)
  STORAGE     - Имя хранилища (для backup/restore/listbackup)
  BACKUP_ID   - ID бэкапа для восстановления (для restore)

Примеры:
  # Создание и управление снапшотами
  $0 create 200 232 "before_update"
  $0 rollback 200 210 "before_update"
  $0 delete 200 232 "old_snapshot"
  
  # Работа с бэкапами
  $0 backup 200 205 "weekly_backup" local-zfs
  $0 listbackup 200 210 local-zfs
  $0 restore 200 200 "" local-zfs "vzdump-qemu-200-2024_01_15-12_30_45.vma.zst"
  
  # Автоматическое восстановление последнего бэкапа
  $0 restore 200 200 "auto" local-zfs
  
  # Просмотр и удаление
  $0 list 200 210
  $0 Destroy 200 232

Особенности restore:
  - Если BACKUP_ID не указан или = "auto", восстанавливается последний бэкап ВМ
  - Если указан конкретный файл бэкапа, восстанавливается именно он
  - ВМ будет остановлена перед восстановлением
  - Можно восстановить бэкап с другим VMID (START != исходный ID)
  - ВМ восстанавливается на хранилище по умолчанию (local-ssd-seagate2tb)
EOF
}

# Если нет параметров - показываем help
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

ACTION=$1
START=$2
END=$3
DESC=$4
STORAGE=$5
BACKUP_ID=$6

# Проверка обязательных параметров
if [ -z "$ACTION" ] || [ -z "$START" ] || [ -z "$END" ]; then
    echo "❌ Ошибка: Необходимо указать ACTION, START и END"
    echo ""
    show_help
    exit 1
fi

# Проверка что START и END - это числа
if ! [[ "$START" =~ ^[0-9]+$ ]] || ! [[ "$END" =~ ^[0-9]+$ ]]; then
    echo "❌ Ошибка: START и END должны быть числами"
    exit 1
fi

# Определяем направление диапазона
if [ $START -le $END ]; then
    VM_RANGE=$(seq $START $END)
else
    VM_RANGE=$(seq $START -1 $END)
fi

# Подсчет количества ВМ
VM_COUNT=$(echo $VM_RANGE | wc -w)

# Проверка обязательных параметров для разных действий
case $ACTION in
    create|rollback|delete)
        if [ -z "$DESC" ]; then
            echo "❌ Ошибка: Для действия '$ACTION' требуется описание (параметр 4)"
            echo ""
            show_help
            exit 1
        fi
        ;;
    backup)
        if [ -z "$DESC" ] || [ -z "$STORAGE" ]; then
            echo "❌ Ошибка: Для действия 'backup' требуется описание (параметр 4) и хранилище (параметр 5)"
            echo ""
            show_help
            exit 1
        fi
        ;;
    restore|listbackup)
        if [ -z "$STORAGE" ]; then
            echo "❌ Ошибка: Для действия '$ACTION' требуется хранилище (параметр 5)"
            echo ""
            show_help
            exit 1
        fi
        ;;
    Destroy)
        # Для Destroy параметры не нужны
        ;;
    list)
        # Для list параметры не нужны
        ;;
    *)
        echo "❌ Ошибка: Неизвестное действие '$ACTION'"
        echo ""
        show_help
        exit 1
        ;;
esac

# Если Destroy, спрашиваем подтверждение
if [[ "$ACTION" == "Destroy" ]]; then
    echo "📋 Диапазон ВМ для удаления: $START → $END (всего: $VM_COUNT ВМ)"
    read -p "⚠️ ВНИМАНИЕ! Удалить ВСЕ ВМ в этом диапазоне? (yes/[no]): " CONFIRM_ALL
    if [[ "$CONFIRM_ALL" != "yes" ]]; then
        echo "Отмена массового удаления."
        exit 0
    fi
fi

# Вывод информации о начале операции
echo "========================================="
echo "Действие: $ACTION"
echo "Диапазон ВМ: $START → $END"
echo "Количество ВМ: $VM_COUNT"
[ -n "$DESC" ] && echo "Описание: $DESC"
[ -n "$STORAGE" ] && echo "Хранилище: $STORAGE"
[ -n "$BACKUP_ID" ] && echo "Бэкап: $BACKUP_ID"
echo "========================================="
echo ""

# Счетчики для статистики
SUCCESS_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

# Функция для получения целевого хранилища ВМ
get_target_storage() {
    # По умолчанию используем local-ssd-seagate2tb
    local default_storage="local"
    
    # Можно добавить логику для определения хранилища на основе VMID или других параметров
    # Например, если есть конфигурационный файл с привязкой VMID к хранилищу
    
    echo "$default_storage"
    return 0
}

# Функция для поиска последнего бэкапа ВМ
find_latest_backup() {
    local vmid=$1
    local storage=$2
    
    # Используем pvesm list для поиска бэкапов
    local backup=$(pvesm list "$storage" 2>/dev/null | \
        grep "vzdump-qemu-${vmid}-" | \
        grep "backup" | \
        awk '{print $1}' | \
        sort -r | \
        head -n 1)
    
    if [ -n "$backup" ]; then
        # Извлекаем только имя файла из полного пути
        basename "$backup" | sed 's|^.*/||'
    else
        echo ""
        return 1
    fi
}

# Функция для получения полного пути к бэкапу через pvesm
get_backup_path() {
    local storage=$1
    local backup_file=$2
    
    # Получаем информацию о бэкапе через pvesm list
    local backup_info=$(pvesm list "$storage" 2>/dev/null | grep "$backup_file" | head -n 1)
    
    if [ -n "$backup_info" ]; then
        # Извлекаем полный путь из первого столбца
        echo "$backup_info" | awk '{print $1}'
    else
        echo ""
        return 1
    fi
}

# Функция для проверки существования бэкапа
backup_exists() {
    local storage=$1
    local backup_file=$2
    
    pvesm list "$storage" 2>/dev/null | grep -q "$backup_file"
    return $?
}

# Основной цикл по всем ВМ
for i in $VM_RANGE; do
    
    case $ACTION in
        create)
            # Проверяем существование ВМ
            if ! qm status $i &>/dev/null; then
                echo "⚠️  ВМ $i не существует — пропуск"
                ((SKIP_COUNT++))
                continue
            fi
            
            SNAP="snap-$(date +%Y%m%d-%H%M%S)"
            echo "📸 Создаю снапшот $SNAP для ВМ $i..."
            if qm snapshot $i "$SNAP" --description "$DESC"; then
                echo "✅ Снапшот создан для ВМ $i"
                ((SUCCESS_COUNT++))
            else
                echo "❌ Ошибка создания снапшота для ВМ $i"
                ((ERROR_COUNT++))
            fi
            ;;
            
        rollback)
            if ! qm status $i &>/dev/null; then
                echo "⚠️  ВМ $i не существует — пропуск"
                ((SKIP_COUNT++))
                continue
            fi
            
            SNAP=$(qm listsnapshot $i 2>/dev/null | grep "$DESC" | tail -n 1 | awk '{print $2}')
            if [ -n "$SNAP" ]; then
                echo "⏮️  Откат ВМ $i к снапшоту $SNAP..."
                if qm rollback $i "$SNAP"; then
                    echo "🚀 Запуск ВМ $i..."
                    qm start $i
                    echo "✅ ВМ $i откачена и запущена"
                    ((SUCCESS_COUNT++))
                else
                    echo "❌ Ошибка отката ВМ $i"
                    ((ERROR_COUNT++))
                fi
            else
                echo "⚠️  У ВМ $i нет снапшота с описанием '$DESC'"
                ((SKIP_COUNT++))
            fi
            ;;
            
        delete)
            if ! qm status $i &>/dev/null; then
                echo "⚠️  ВМ $i не существует — пропуск"
                ((SKIP_COUNT++))
                continue
            fi
            
            SNAPS=$(qm listsnapshot $i 2>/dev/null | grep "$DESC" | awk '{print $2}')
            if [ -n "$SNAPS" ]; then
                SNAP_COUNT=$(echo "$SNAPS" | wc -l)
                echo "🗑️  Найдено $SNAP_COUNT снапшот(ов) для ВМ $i"
                for s in $SNAPS; do
                    echo "   Удаляю снапшот $s..."
                    if qm delsnapshot $i "$s"; then
                        echo "   ✅ Снапшот $s удален"
                    else
                        echo "   ❌ Ошибка удаления снапшота $s"
                        ((ERROR_COUNT++))
                    fi
                done
                ((SUCCESS_COUNT++))
            else
                echo "⚠️  У ВМ $i нет снапшотов с описанием '$DESC'"
                ((SKIP_COUNT++))
            fi
            ;;
            
        backup)
            if ! qm status $i &>/dev/null; then
                echo "⚠️  ВМ $i не существует — пропуск"
                ((SKIP_COUNT++))
                continue
            fi
            
            echo "💾 Создаю бэкап ВМ $i в хранилище $STORAGE..."
            if vzdump $i --storage "$STORAGE" --mode snapshot --compress zstd \
                   --remove 0 --notes-template "$DESC"; then
                echo "✅ Бэкап ВМ $i создан"
                ((SUCCESS_COUNT++))
            else
                echo "❌ Ошибка создания бэкапа ВМ $i"
                ((ERROR_COUNT++))
            fi
            ;;
            
        restore)
            echo "🔄 Восстановление ВМ $i..."
            
            # Определяем целевое хранилище для ВМ
            TARGET_STORAGE=$(get_target_storage $i)
            echo "   🎯 Целевое хранилище для ВМ: $TARGET_STORAGE"
            
            # Определяем какой бэкап использовать
            if [ -z "$BACKUP_ID" ] || [ "$BACKUP_ID" == "auto" ]; then
                echo "   🔍 Поиск последнего бэкапа для ВМ $i..."
                BACKUP_FILE=$(find_latest_backup $i "$STORAGE")
                if [ -z "$BACKUP_FILE" ]; then
                    echo "   ⚠️  Бэкап для ВМ $i не найден в хранилище $STORAGE"
                    ((SKIP_COUNT++))
                    continue
                fi
                echo "   📦 Найден бэкап: $BACKUP_FILE"
            else
                BACKUP_FILE="$BACKUP_ID"
                if ! backup_exists "$STORAGE" "$BACKUP_FILE"; then
                    echo "   ❌ Бэкап файл не найден в хранилище: $BACKUP_FILE"
                    ((ERROR_COUNT++))
                    continue
                fi
                echo "   📦 Используем указанный бэкап: $BACKUP_FILE"
            fi
            
            # Получаем полный путь к бекапу через pvesm
            BACKUP_PATH=$(get_backup_path "$STORAGE" "$BACKUP_FILE")
            if [ -z "$BACKUP_PATH" ]; then
                echo "   ❌ Не удалось определить путь к бэкапу: $BACKUP_FILE"
                ((ERROR_COUNT++))
                continue
            fi
            
            echo "   🔍 Полный путь к бэкапу: $BACKUP_PATH"
            
            # Проверяем существует ли ВМ
            if qm status $i &>/dev/null; then
                echo "   ⚠️  ВМ $i уже существует"
                read -p "   Удалить существующую ВМ $i и восстановить из бэкапа? (yes/[no]): " CONFIRM_RESTORE
                if [[ "$CONFIRM_RESTORE" != "yes" ]]; then
                    echo "   ⏭️  Пропуск ВМ $i"
                    ((SKIP_COUNT++))
                    continue
                fi
                
                echo "   🛑 Останавливаю ВМ $i..."
                qm stop $i 2>/dev/null
                sleep 2
                
                echo "   🗑️  Удаляю существующую ВМ $i..."
                if ! qm destroy $i; then
                    echo "   ❌ Не удалось удалить ВМ $i"
                    ((ERROR_COUNT++))
                    continue
                fi
            fi
            
            # Восстанавливаем из бэкапа на целевое хранилище
            echo "   📥 Восстанавливаю ВМ $i из бэкапа $BACKUP_FILE на хранилище $TARGET_STORAGE..."
            if qmrestore "$BACKUP_PATH" $i --storage "$TARGET_STORAGE"; then
                echo "   ✅ ВМ $i успешно восстановлена на хранилище $TARGET_STORAGE"
                
                # Опционально: запускаем ВМ после восстановления
                read -p "   Запустить ВМ $i? (yes/[no]): " START_VM
                if [[ "$START_VM" == "yes" ]]; then
                    echo "   🚀 Запускаю ВМ $i..."
                    qm start $i
                fi
                
                ((SUCCESS_COUNT++))
            else
                echo "   ❌ Ошибка восстановления ВМ $i на хранилище $TARGET_STORAGE"
                ((ERROR_COUNT++))
            fi
            ;;
            
        listbackup)
            echo "📦 Бэкапы для ВМ $i в хранилище $STORAGE:"
            
            BACKUPS=$(pvesm list "$STORAGE" 2>/dev/null | \
                grep "vzdump-qemu-${i}-" | \
                grep "backup" | \
                awk '{print $1, $4, $5}' | \
                sort -r)
            
            if [ -n "$BACKUPS" ]; then
                while IFS= read -r backup_line; do
                    if [ -n "$backup_line" ]; then
                        backup_file=$(echo "$backup_line" | awk '{print $1}' | sed 's|^.*/||')
                        backup_size=$(echo "$backup_line" | awk '{print $2}')
                        backup_vmid=$(echo "$backup_line" | awk '{print $3}')
                        echo "   📄 $backup_file  ${backup_size}  VMID:${backup_vmid}"
                    fi
                done <<< "$BACKUPS"
                ((SUCCESS_COUNT++))
            else
                echo "   ⚠️  Бэкапы не найдены"
                ((SKIP_COUNT++))
            fi
            echo ""
            ;;
            
        Destroy)
            if ! qm status $i &>/dev/null; then
                echo "⚠️  ВМ $i не существует — пропуск"
                ((SKIP_COUNT++))
                continue
            fi
            
            echo "💥 Удаляю ВМ $i..."
            if qm destroy $i; then
                echo "✅ ВМ $i удалена"
                ((SUCCESS_COUNT++))
            else
                echo "❌ Ошибка удаления ВМ $i"
                ((ERROR_COUNT++))
            fi
            ;;
            
        list)
            if ! qm status $i &>/dev/null; then
                echo "⚠️  ВМ $i не существует — пропуск"
                ((SKIP_COUNT++))
                continue
            fi
            
            echo "📋 ВМ $i:"
            STATUS=$(qm status $i 2>/dev/null | awk '{print $2}')
            echo "   Статус: $STATUS"
            echo "   Снапшоты:"
            qm listsnapshot $i 2>/dev/null | tail -n +2 || echo "   (нет снапшотов)"
            echo ""
            ((SUCCESS_COUNT++))
            ;;
    esac
done

# Итоговая статистика
echo ""
echo "========================================="
echo "📊 СТАТИСТИКА ВЫПОЛНЕНИЯ"
echo "========================================="
echo "✅ Успешно: $SUCCESS_COUNT"
echo "⚠️  Пропущено: $SKIP_COUNT"
echo "❌ Ошибок: $ERROR_COUNT"
echo "📝 Всего обработано: $((SUCCESS_COUNT + SKIP_COUNT + ERROR_COUNT)) из $VM_COUNT"
echo "========================================="

# Возвращаем код ошибки если были ошибки
if [ $ERROR_COUNT -gt 0 ]; then
    exit 1
fi
