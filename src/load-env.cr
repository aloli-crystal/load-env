require "./load-env/version"

# Chargeur `.env` minimaliste, Crystal pur, zéro dépendance externe.
#
# Parse les formats usuels `KEY=VALUE`, `KEY="..."`, `KEY='...'`,
# `export KEY=...`, ignore les lignes vides et les commentaires (`#`).
# Pose les variables dans `ENV` sans écraser par défaut (les variables
# déjà définies dans le shell ou en CLI restent prioritaires).
#
# Usage typique au démarrage d'un CLI :
#
#     require "load-env"
#     LoadEnv.load              # charge `.env` dans le cwd, silencieux si absent
#     LoadEnv.load(".env.prod") # autre chemin
#     LoadEnv.load(overwrite: true)
#
# Les valeurs entre guillemets conservent leurs espaces internes ; les
# séquences `\n`, `\r`, `\t`, `\\`, `\"` sont déséchappées dans les
# chaînes à guillemets doubles (bash-like). Les guillemets simples sont
# littéraux. Un commentaire de fin de ligne (précédé d'un espace) est
# retiré sur les valeurs non quotées (`FOO=bar # note`).
module LoadEnv
  # Charge un fichier `.env` dans `ENV` (silencieux si absent).
  #
  # `overwrite: false` (défaut) : n'écrase pas les variables déjà
  # présentes dans `ENV`. Convention : ce qui est explicitement exporté
  # avant d'invoquer le programme l'emporte sur le fichier.
  #
  # Retourne le nombre de variables effectivement posées.
  def self.load(path : String = ".env", overwrite : Bool = false) : Int32
    return 0 unless File.exists?(path)

    count = 0
    parse(File.read(path)).each do |key, value|
      next if !overwrite && ENV.has_key?(key)
      ENV[key] = value
      count += 1
    end
    count
  end

  # Parse un contenu `.env` en `Hash(String, String)`.
  # Utile pour les tests et pour accéder aux variables sans toucher `ENV`.
  def self.parse(content : String) : Hash(String, String)
    result = {} of String => String
    content.each_line do |raw|
      line = raw.strip
      next if line.empty? || line.starts_with?('#')

      # `export FOO=bar` est accepté pour la compatibilité avec les .env
      # rédigés pour être aussi sourçables par `bash`.
      line = line.sub(/^export\s+/, "")

      eq = line.index('=')
      next unless eq
      key = line[0...eq].strip
      next if key.empty?

      value = line[(eq + 1)..].strip
      result[key] = unquote(value)
    end
    result
  end

  # Retire les guillemets entourants et déséchappe les séquences bash
  # usuelles (doubles guillemets uniquement).
  private def self.unquote(value : String) : String
    return "" if value.empty?

    if value.size >= 2 && value.starts_with?('"') && value.ends_with?('"')
      inner = value[1...-1]
      inner
        .gsub("\\n", "\n")
        .gsub("\\r", "\r")
        .gsub("\\t", "\t")
        .gsub("\\\"", "\"")
        .gsub("\\\\", "\\")
    elsif value.size >= 2 && value.starts_with?('\'') && value.ends_with?('\'')
      value[1...-1]
    else
      # Valeur non quotée : on retire un commentaire de fin de ligne
      # précédé d'un espace (`FOO=bar # note`).
      if idx = value.index(" #")
        value[0...idx].rstrip
      else
        value
      end
    end
  end
end
