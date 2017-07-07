require "tempfile"
require "json"
require "optparse"
require "set"
require "fileutils"

def safe_write(path, content)
  dir = File.dirname(path)
  begin
    FileUtils.mkdir_p(dir)
  rescue Errno::EEXIST #don't care
  end
  temp_path = path.to_s + ".tmp"
  File.open(temp_path, 'w+') do |f|
    f.write(content)
  end

  FileUtils.mv(temp_path, path)
end

def parse_perf_report(file)
  edges = []
  file.map do |line|
    next if line =~ /^#/
    parts = line.split
    if parts.size != 5
      next
    end
    comm, _, from_src, _, to_src = parts
    #if parts.size != 3
    #  # perf guys have never spaces in their source paths
    #  next
    #end
    #if !from_src.start_with?("/") || !to_src.start_with?("/")
    #  next # unresolved calls / jumps
    #end
    edges << [ comm, from_src, to_src ]
  end
  edges
end

def run_perf(prog, args)
  file = Tempfile.new
  begin
    system(*["perf", "record",
             "-e", "cycles:u",
             #"-j", "ind_call,ind_jmp,u",
             "-j", "ind_call,u",
             "--output", file.path, "--",
             prog] + args)
    perf_record = ["perf",
                   "report",
                   "--input", file.path,
                   "--fields", "comm,symbol_from,symbol_to",
                   #"--full-source-path",
                   #"--fields", "comm,srcline_from,srcline_to",
                   "-U", "--stdio"]
    puts("$ #{perf_record.join(" ")}")
    IO.popen(perf_record) do |stream|
      return parse_perf_report(stream)
    end
  ensure
    file.close
    file.unlink
  end
end

def parse_args(args)
  options = {
    branches_database: "indirect-branches.json",
    commands: []
  }
  optparse = OptionParser.new do |opts|
    opts.banner = "USAGE: #{$0} [options] -- command args.."
    opts.on("-c", "--commands COMMANDS", String, "comma-seperated list commands to record") do |commands|
      options[:commands] = commands.split(/,/)
    end
    opts.on("--branches-database FILE", String,
            "where to write json file (default: #{options[:branches_database]})") do |database|
      options[:branches_database] = database
    end
  end
  optparse.parse!(args)
  if args.size < 1
    $stderr.puts("not enough arguments!")
    $stderr.puts(optparse.banner)
    exit(1)
  end
  options[:command] = args[0]
  options[:command_args] = args[1..-1] || []
  options
end

def main(args)
  options = parse_args(args)
  edges = run_perf(options[:command], options[:command_args])
  commands = Set.new(options[:commands])
  wanted_edges = []
  ignored_commands = Set.new
  edges.each do |edge|
    unless commands.include?(edge[0])
      ignored_commands << edge[0]
      next
    end
    wanted_edges << [edge[1], edge[2]]
  end
  old_edges = if File.file?(options[:branches_database])
                json = JSON.load(open(options[:branches_database]))
                json["edges"]
              else
                []
              end
  puts("ignored commands: #{ignored_commands.to_a.join(",")}")
  new_edges = Set.new
  new_edges.merge(old_edges)
  new_edges.merge(wanted_edges)

  safe_write(options[:branches_database],
             JSON.pretty_generate({ edges: new_edges.to_a }))
end

main(ARGV)
