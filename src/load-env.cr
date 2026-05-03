require "log"

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
#     LoadEnv.load              # charge `.env` dans le cwd
#     LoadEnv.load(".env.prod") # autre chemin
#     LoadEnv.load(overwrite: true)
#     LoadEnv.load(quiet: true) # n'émet aucun log
#
# Les valeurs entre guillemets conservent leurs espaces internes ; les
# séquences `\n`, `\r`, `\t`, `\\`, `\"` sont déséchappées dans les
# chaînes à guillemets doubles (bash-like). Les guillemets simples sont
# littéraux. Un commentaire de fin de ligne (précédé d'un espace) est
# retiré sur les valeurs non quotées (`FOO=bar # note`).
#
# Logging :
#
# * `INFO` à chaque chargement réussi : chemin résolu (absolu), nombre
#   de variables posées, nombre laissées de côté (déjà présentes dans
#   ENV ou skippées par `overwrite: false`). *Aucune clé ni valeur* —
#   pas de fuite de secret dans les journaux.
# * `WARN` si le chemin demandé n'existe pas — pratique pour repérer
#   un mauvais cwd ou un .env oublié (cas vécu : un wrapper rc.d qui
#   ne fait pas `cd` avant d'`exec` le binaire, le .env est invisible).
# * Silencieux complet via `quiet: true` (tests, chargements multiples).
module LoadEnv
  Log = ::Log.for(self)

  # Charge un fichier `.env` dans `ENV`.
  #
  # `overwrite: false` (défaut) : n'écrase pas les variables déjà
  # présentes dans `ENV`. Convention : ce qui est explicitement exporté
  # avant d'invoquer le programme l'emporte sur le fichier.
  #
  # `quiet: false` (défaut) : émet une ligne `INFO` au succès, `WARN`
  # si fichier absent. Aucune clé ni valeur n'est loggée.
  #
  # Retourne le nombre de variables effectivement posées.
  def self.load(path : String = ".env", overwrite : Bool = false, quiet : Bool = false) : Int32
    abs = File.expand_path(path)
    unless File.exists?(path)
      Log.warn { ".env introuvable au chemin demandé : #{abs}" } unless quiet
      return 0
    end

    count = 0
    skipped = 0
    parse(File.read(path)).each do |key, value|
      if !overwrite && ENV.has_key?(key)
        skipped += 1
        next
      end
      ENV[key] = value
      count += 1
    end
    Log.info { ".env chargé depuis #{abs} : #{count} variable(s) posée(s), #{skipped} ignorée(s) (déjà dans ENV)" } unless quiet
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
