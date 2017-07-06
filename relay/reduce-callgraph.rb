#!/usr/bin/env ruby

require "pry"
require "json"
require "set"

def parse_function_node(node)
    function_name, type, function_id = node.split(':')
    {
      function_name: function_name,
      function_id: function_id,
      function_type: type,
    }
end

def parse_relay_callgraph(path)
  callgraph = open(path).map do |line|
    filename, function_node, callees_token = line.strip.split('$')
    callees = []
    unless callees_token.nil?
      callees_token.scan(/(false|true):\((\d+, \d+)\){([^}]+)}/) do |is_indirect_token, position, node|
        is_indirect = is_indirect_token == "true"
        nodes = if is_indirect
                  node.split("/")
                else
                  [node]
                end
        callees << {
          is_indirect: is_indirect,
          position: position,
          nodes: nodes.map do |n|
            parse_function_node(n)
          end
        }
      end
    end

    function = parse_function_node(function_node)
    function[:filename] = filename
    function[:callees] = callees
    function
  end

  callgraph
end

def write_relay_callgraph(path)
  callgraph = open(path).map do |line|
    filename, function_node, callees_token = line.strip.split('$')
    callees = []
    unless callees_token.nil?
      callees_token.scan(/(false|true):\((\d+, \d+)\){([^}]+)}/) do |is_indirect_token, position, node|
        is_indirect = is_indirect_token == "true"
        nodes = if is_indirect
                  node.split("/")
                else
                  [node]
                end
        callees << {
          is_indirect: is_indirect,
          position: position,
          nodes: nodes.map do |n|
            parse_function_node(n)
          end
        }
      end
    end

    function = parse_function_node(function_node)
    function[:filename] = filename
    function[:callees] = callees
    function
  end

  callgraph
end

def normalized_function_name(name)
  # strip libc large file support
  name.gsub(/__/, "").gsub(/(64$|^GI___|^GI__|^GI_libc_|^GI_|^libc_|@[^@]*$)/, "")
end

def optimize_callgraph(callgraph, edges)
  stats = Hash.new(0)
  observed_callgraph = Hash.new {|hsh, key| hsh[key] = Set.new }
  edges.each do |edge|
    observed_callgraph[normalized_function_name(edge[0])] << normalized_function_name(edge[1])
  end

  callgraph.each do |function|
    observed_targets = observed_callgraph[normalized_function_name(function[:function_name])]
    function[:callees].each do |callee|
      next unless callee[:is_indirect]
      new_nodes = callee[:nodes].select do |node|
        node_name = normalized_function_name(node[:function_name])
        observed_targets.include?(node_name)
      end
      if new_nodes.empty?
        puts("function_name: #{function[:function_name]}")
        puts("callee type: #{callee[:nodes].first[:function_type]}")
        puts("computed: #{callee[:nodes].map {|node| node[:function_name]}.join(" ")}")
        puts("seen: #{observed_targets.to_a.join(" ")}")
        puts("------------------------")
        stats[:empty_indirect_calls] += 1
      else
        stats[:call_target_reduction] += new_nodes.size.to_f / callee[:nodes].size
        stats[:call_sites] += 1
      end
      callee[:nodes] = new_nodes
    end
  end
  stats[:call_target_reduction] /= stats[:call_sites]
  callgraph
end

def main(args)
  if args.size < 2
    $stderr.puts("USAGE #{$0} path/to/ciltrees/calls.steen indirect-branches.json")
    exit(1)
  end
  callgraph = parse_relay_callgraph(args[0])
  #puts JSON.pretty_generate(calls)
  functions_with_indirect_calls = callgraph.find_all do |call|
    call[:callees].any? {|callee| callee[:is_indirect] }
  end
  puts("functions: #{callgraph.size}")
  percent = functions_with_indirect_calls.size.to_f / callgraph.size  * 100
  puts("functions with indirect calls: #{functions_with_indirect_calls.size} (#{percent.round(3)}%)")

  indirect_calls = JSON.load(open(args[1]))
  optimize_callgraph(callgraph, indirect_calls["edges"])
end

main(ARGV)
