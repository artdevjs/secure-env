# imports from standard library
##
import os
import yaml
import streams
import strutils
import tempfile
import db_sqlite
import parseopt2

type SecureEnvConfiguration= object
  database: string
  encrypt_cmd: string
  decrypt_cmd: string

type SubCommand {.pure.} = enum
  None,
  Get,
  Set,
  List,

var current_command = SubCommand.None

# get progname
##
proc progname(): string =
  result = os.extractFilename(os.getAppFilename())

# define the usage for "--help"
##
proc usage =
  case current_command:
  of SubCommand.None: echo("usage: " & progname() & " [--help|-h] [--version] [get|set|list] ...")
  of SubCommand.Get:  echo("usage: " & progname() & " get --key:<name of secret>")
  of SubCommand.Set:  echo("usage: " & progname() & " set --key:<name of secret> --value:<secret>")
  of SubCommand.List: echo("usage: " & progname() & " list")
  quit(QuitSuccess)

# define the version number
##
proc version_info =
  echo progname() & " v0.3"
  quit(QuitSuccess)

proc encryptData(config_data: SecureEnvConfiguration, input: string): string {.gcsafe.} =
  let (_, plain_path) = tempfile.mkstemp()
  os.removeFile(plain_path)
  let (_, encrypted_path) = tempfile.mkstemp()
  os.removeFile(encrypted_path)
  
  let fd = open(plain_path, fmWrite)
  write(fd, input)
  fd.close()
  
  let exec_command = strutils.replace(config_data.encrypt_cmd, "{input}", plain_path).replace("{output}", encrypted_path)
  let status = os.execShellCmd(exec_command)
  os.removeFile(plain_path)
  
  let output = open(encrypted_path)
  var output_data: seq[string] = newSeq[string]()
  while not endOfFile(output):
    let hex_byte = readChar(output)
    let byte_rep = strutils.format("$1", ord(hex_byte))
    add(output_data, byte_rep)
  output.close()
  os.removeFile(encrypted_path)
  
  return strutils.join(output_data, ":")
  
proc decryptData(config_data: SecureEnvConfiguration, input: string): string {.gcsafe.} =
  let (_, encrypted_path) = tempfile.mkstemp()
  os.removeFile(encrypted_path)
  let (_, plain_path) = tempfile.mkstemp()
  os.removeFile(plain_path)
  
  let fd = open(encrypted_path, fmWrite)
  for byte_rep in strutils.split(input, ":"):
    let hex_byte_int = strutils.parseUInt(byte_rep)
    let hex_byte = chr(hex_byte_int)
    write(fd, hex_byte)
  fd.close()
  
  let exec_command = strutils.replace(config_data.decrypt_cmd, "{input}", encrypted_path).replace("{output}", plain_path)
  let status = os.execShellCmd(exec_command)
  os.removeFile(encrypted_path)

  let output = open(plain_path)
  let output_data = readAll(output)
  output.close()
  os.removeFile(plain_path)
  
  return output_data.string

# ===========================================
# this is the entry-point, there is no main()
# ===========================================

var config_data: SecureEnvConfiguration

let default_prefs_path = os.expandTilde("~/.config/secure-env/config.yml")
let alternative_prefs_path = os.getEnv("SECURE_ENV_CONFIG")

let use_alternative_config_path: bool = os.existsEnv("SECURE_ENV_CONFIG") and alternative_prefs_path.len > 0

let load_prefs_path: string = 
  if use_alternative_config_path: alternative_prefs_path
  else: default_prefs_path

var token_key: string = ""
var token_value: string = ""

for kind, key, value in parseopt2.getopt():
  case kind
  of cmdLongOption, cmdShortOption:
    case key
    of "version": version_info()
    of "help", "h": usage()
    else:
      case current_command
      of SubCommand.Get:
        case key
        of "key": token_key = value
        else: discard
      of SubCommand.Set:
        case key
        of "key": token_key = value
        of "value": token_value = value
        else: discard
      else: discard
  of cmdArgument:
    case key:
    of "get":  current_command = SubCommand.Get
    of "set":  current_command = SubCommand.Set
    of "list": current_command = Subcommand.List
    else: discard
  else: discard

if not os.existsFile(load_prefs_path):
  echo("Unable to locate the config file, please create it at `~/.config/secure-env/config.yml` or define `SECURE_ENV_CONFIG` in your environment")
  quit(QuitFailure)

let config_stream = streams.newFileStream(load_prefs_path)
yaml.serialization.load(config_stream, config_data)
config_stream.close()

let database_path = os.expandTilde(config_data.database)

let secure_db = db_sqlite.open(database_path, nil, nil, nil)
db_sqlite.exec(secure_db, sql"CREATE TABLE IF NOT EXISTS vault (id INTEGER PRIMARY KEY, key TEXT, value BLOB)")

case current_command
of SubCommand.None:
  echo("please specify a subcommand! (run `secure-env --help` for more information)")
of SubCommand.Get:
  let encrypted_value = db_sqlite.getValue(secure_db, sql"SELECT value FROM vault WHERE key = ?", token_key)
  if encrypted_value.len > 0:
    let decrypted_value  = decryptData(config_data, encrypted_value)
    echo(decrypted_value)
of SubCommand.Set:
  if token_value.len == 0:
    db_sqlite.exec(secure_db, sql"DELETE FROM vault WHERE key = ?", token_key)
  else:
    let exists = db_sqlite.getValue(secure_db, sql"SELECT id FROM vault WHERE key = ?", token_key)
    let encrypted_value = encryptData(config_data, token_value)
    if exists.len > 0:
      db_sqlite.exec(secure_db, sql"UPDATE vault SET value = ? WHERE key = ?", $encrypted_value, token_key)
    else:
      discard db_sqlite.insertID(secure_db, sql"INSERT INTO vault(key, value) VALUES (?, ?)", token_key, encrypted_value)
of SubCommand.List:
  for row in db_sqlite.fastRows(secure_db, sql"SELECT id,key FROM vault"):
    echo(row[1])

db_sqlite.close(secure_db)
