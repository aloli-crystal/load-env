require "./spec_helper"

# Capture les logs émis par le module LoadEnv via un Log::MemoryBackend.
# Permet d'assurer que la ligne INFO/WARN sort bien et qu'aucune
# clé ni valeur n'y figure (évite la fuite de secret en logs).
private def with_log_capture(&)
  backend = ::Log::MemoryBackend.new
  previous = LoadEnv::Log.backend
  LoadEnv::Log.backend = backend
  LoadEnv::Log.level = ::Log::Severity::Trace
  begin
    yield backend
  ensure
    LoadEnv::Log.backend = previous
  end
end

describe LoadEnv do
  it "expose une version" do
    LoadEnv::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
  end

  describe ".parse" do
    it "parse des paires simples KEY=VALUE" do
      h = LoadEnv.parse("FOO=bar\nBAZ=qux\n")
      h["FOO"].should eq("bar")
      h["BAZ"].should eq("qux")
    end

    it "ignore lignes vides et commentaires" do
      h = LoadEnv.parse("# commentaire\n\nFOO=bar\n# autre\n")
      h.size.should eq(1)
      h["FOO"].should eq("bar")
    end

    it "accepte le préfixe 'export ' (compat source bash)" do
      h = LoadEnv.parse("export FOO=bar\n")
      h["FOO"].should eq("bar")
    end

    it "déséchappe les séquences dans les guillemets doubles" do
      h = LoadEnv.parse(%(LINE="a\\nb\\tc"))
      h["LINE"].should eq("a\nb\tc")
    end

    it "déséchappe \\\" et \\\\ dans les guillemets doubles" do
      h = LoadEnv.parse(%(Q="a\\"b\\\\c"))
      h["Q"].should eq("a\"b\\c")
    end

    it "conserve le contenu littéral dans les guillemets simples" do
      h = LoadEnv.parse(%(LIT='a\\nb'))
      h["LIT"].should eq("a\\nb")
    end

    it "retire les commentaires de fin de ligne sur valeurs non quotées" do
      h = LoadEnv.parse("FOO=bar # commentaire\n")
      h["FOO"].should eq("bar")
    end

    it "ne retire pas les `#` internes aux valeurs quotées" do
      h = LoadEnv.parse(%(FOO="bar # contenu"))
      h["FOO"].should eq("bar # contenu")
    end

    it "ignore une ligne sans signe égal" do
      h = LoadEnv.parse("PAS_DE_EGAL\nFOO=bar\n")
      h.size.should eq(1)
      h["FOO"].should eq("bar")
    end

    it "autorise un signe égal dans la valeur" do
      h = LoadEnv.parse("SIG=secret=abc=123\n")
      h["SIG"].should eq("secret=abc=123")
    end

    it "ignore une ligne avec clé vide (=valeur seul)" do
      h = LoadEnv.parse("=orphelin\nFOO=bar\n")
      h.size.should eq(1)
      h["FOO"].should eq("bar")
    end

    it "valeur vide autorisée" do
      h = LoadEnv.parse("VIDE=\nFOO=bar\n")
      h["VIDE"].should eq("")
      h["FOO"].should eq("bar")
    end
  end

  describe ".load" do
    it "renvoie 0 si le fichier n'existe pas" do
      LoadEnv.load("/tmp/load-env-absent-#{Random.rand(100_000)}.env", quiet: true).should eq(0)
    end

    it "pose les variables dans ENV mais n'écrase pas par défaut" do
      path = File.tempfile("load-env", ".env") do |f|
        f.print "LOADENV_TEST_NEW=poseur\nLOADENV_TEST_EXISTING=nouveau\n"
      end
      begin
        ENV.delete("LOADENV_TEST_NEW")
        ENV["LOADENV_TEST_EXISTING"] = "ancien"

        posed = LoadEnv.load(path.path, quiet: true)
        posed.should eq(1)
        ENV["LOADENV_TEST_NEW"].should eq("poseur")
        ENV["LOADENV_TEST_EXISTING"].should eq("ancien")
      ensure
        path.delete
        ENV.delete("LOADENV_TEST_NEW")
        ENV.delete("LOADENV_TEST_EXISTING")
      end
    end

    it "overwrite: true écrase bien les variables existantes" do
      path = File.tempfile("load-env", ".env") do |f|
        f.print "LOADENV_TEST_OW=nouveau\n"
      end
      begin
        ENV["LOADENV_TEST_OW"] = "ancien"
        LoadEnv.load(path.path, overwrite: true, quiet: true)
        ENV["LOADENV_TEST_OW"].should eq("nouveau")
      ensure
        path.delete
        ENV.delete("LOADENV_TEST_OW")
      end
    end
  end

  describe ".load logging" do
    it "log INFO sur succès avec chemin absolu, comptes posés/ignorés, sans clés ni valeurs" do
      path = File.tempfile("load-env", ".env") do |f|
        f.print "LOADENV_LOG_NEW=secret-ne-doit-pas-apparaitre\nLOADENV_LOG_EXISTING=ignored\n"
      end
      begin
        ENV.delete("LOADENV_LOG_NEW")
        ENV["LOADENV_LOG_EXISTING"] = "ancien"

        with_log_capture do |backend|
          LoadEnv.load(path.path)
          msgs = backend.entries.map(&.message)
          msgs.size.should eq 1
          info = msgs.first
          info.should contain ".env chargé"
          info.should contain File.expand_path(path.path)
          info.should contain "1 variable(s) posée(s)"
          info.should contain "1 ignorée(s)"
          # Ni les clés ni les valeurs ne doivent fuiter dans le log.
          info.should_not contain "LOADENV_LOG_NEW"
          info.should_not contain "LOADENV_LOG_EXISTING"
          info.should_not contain "secret-ne-doit-pas-apparaitre"
          info.should_not contain "ancien"
        end
      ensure
        path.delete
        ENV.delete("LOADENV_LOG_NEW")
        ENV.delete("LOADENV_LOG_EXISTING")
      end
    end

    it "log WARN si le fichier est introuvable, avec le chemin absolu tenté" do
      path = "/tmp/load-env-absent-#{Random.rand(100_000)}.env"
      with_log_capture do |backend|
        LoadEnv.load(path)
        backend.entries.size.should eq 1
        entry = backend.entries.first
        entry.severity.should eq ::Log::Severity::Warn
        entry.message.should contain ".env introuvable"
        entry.message.should contain File.expand_path(path)
      end
    end

    it "quiet: true coupe tous les logs (succès comme erreur)" do
      with_log_capture do |backend|
        LoadEnv.load("/tmp/absent.env", quiet: true)
        backend.entries.should be_empty
      end

      path = File.tempfile("load-env", ".env") do |f|
        f.print "LOADENV_QUIET_OK=1\n"
      end
      begin
        ENV.delete("LOADENV_QUIET_OK")
        with_log_capture do |backend|
          LoadEnv.load(path.path, quiet: true)
          backend.entries.should be_empty
        end
      ensure
        path.delete
        ENV.delete("LOADENV_QUIET_OK")
      end
    end
  end
end
