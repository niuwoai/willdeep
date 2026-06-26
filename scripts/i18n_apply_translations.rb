# frozen_string_literal: true
# 把翻译批次(zh-Hans)与新 key(en+zh)合并进 Localizable.xcstrings。
# 关键:自定义序列化器逐字节复刻 Xcode 的 xcstrings 排版,unchanged 条目
# 输出与原文件完全一致,diff 只剩真正新增的内容。
#
# 用法:
#   ruby scripts/i18n_apply_translations.rb --verify           # 空跑往返,校验序列化器无损
#   ruby scripts/i18n_apply_translations.rb <translated_dir> <new_keys.json>
require "json"

XCSTRINGS = File.join(__dir__, "..", "Xedit", "Localizable.xcstrings")

# ---- Xcode 风格序列化器 ----
def dump_value(val, indent)
  pad = "  " * indent
  case val
  when Hash
    return "{\n\n#{pad}}" if val.empty?
    inner = val.map do |k, v|
      "#{pad}  #{k.to_json} : #{dump_value(v, indent + 1)}"
    end.join(",\n")
    "{\n#{inner}\n#{pad}}"
  when Array
    return "[\n\n#{pad}]" if val.empty?
    inner = val.map { |v| "#{pad}  #{dump_value(v, indent + 1)}" }.join(",\n")
    "[\n#{inner}\n#{pad}]"
  else
    val.to_json
  end
end

def dump_xcstrings(data)
  # 原文件结尾无换行符,保持一致以保证往返逐字节相等。
  dump_value(data, 0)
end

def load_data
  JSON.parse(File.read(XCSTRINGS, encoding: "UTF-8"))
end

# ---- 校验模式:parse → dump 应与原文件逐字节一致 ----
if ARGV[0] == "--verify"
  original = File.read(XCSTRINGS, encoding: "UTF-8")
  rebuilt = dump_xcstrings(load_data)
  if original == rebuilt
    puts "OK: 序列化器无损,往返与原文件逐字节一致"
  else
    # 找第一处差异
    olines = original.lines
    rlines = rebuilt.lines
    idx = olines.zip(rlines).index { |a, b| a != b }
    puts "FAIL: 第一处差异在第 #{idx ? idx + 1 : '?'} 行"
    if idx
      puts "  原: #{olines[idx].inspect}"
      puts "  新: #{rlines[idx].inspect}"
    end
    puts "  原行数=#{olines.size} 新行数=#{rlines.size}"
    exit 1
  end
  exit 0
end

translated_dir = ARGV[0] or abort "need <translated_dir>"
new_keys_path = ARGV[1] or abort "need <new_keys.json>"

data = load_data
strings = data["strings"]
added_zh = 0
created = 0
skipped_existing = 0

def zh_unit(value)
  { "stringUnit" => { "state" => "translated", "value" => value } }
end

# 1) 已有 key 补 zh-Hans 翻译
Dir.glob(File.join(translated_dir, "translated_batch_*.json")).sort.each do |f|
  JSON.parse(File.read(f, encoding: "UTF-8")).each do |key, zh|
    entry = strings[key]
    next unless entry # 该 key 不在 catalog(理论上不会),跳过
    loc = (entry["localizations"] ||= {})
    if loc.key?("zh-Hans")
      skipped_existing += 1
      next
    end
    loc["zh-Hans"] = zh_unit(zh)
    added_zh += 1
  end
end

# 2) 新 key:en + zh-Hans
new_keys = JSON.parse(File.read(new_keys_path, encoding: "UTF-8"))
new_keys.each do |key, pair|
  if strings.key?(key)
    # 已存在(可能上一轮已加),只补缺的 localization
    loc = (strings[key]["localizations"] ||= {})
    loc["en"] ||= zh_unit(pair["en"])
    loc["zh-Hans"] ||= zh_unit(pair["zh"])
  else
    strings[key] = {
      "extractionState" => "manual",
      "localizations" => {
        "en" => zh_unit(pair["en"]),
        "zh-Hans" => zh_unit(pair["zh"]),
      },
    }
    created += 1
  end
end

File.write(XCSTRINGS, dump_xcstrings(data))
puts "补 zh-Hans 翻译: #{added_zh} 条"
puts "跳过(已有 zh-Hans): #{skipped_existing} 条"
puts "新增 key: #{created} 条"
puts "当前总 key: #{strings.size}"
