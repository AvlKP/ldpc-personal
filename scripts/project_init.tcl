set script_dir [file normalize [file dirname [info script]]]
set get_board_base [file join $script_dir "get_board"]

# check if board file is available
set platform $tcl_platform(platform)
set pynq_z1_exists [llength [get_boards -quiet *pynq-z1*]]

if { $pynq_z1_exists == 0 } {
  puts "Board file for PYNQ-Z1 not found. Downloading board file ..."

  if { $platform == "windows" } {
    set get_board_path "${get_board_base}.ps1"
    set status [catch {exec powershell -ExecutionPolicy Bypass -File $get_board_path "temp" $env(XILINX_VIVADO)} result]
  } else {
    set get_board_path "${get_board_base}.sh"
    set status [catch {exec $get_board_path "temp" $env(XILINX_VIVADO)} result] 
  }

  if { $status != 0 } {
    puts "Failed to download board file. Please check the error message above."
    exit 1
  }
}

# create project
set project_dir [file join [pwd] "vivado" "project"]
if { [expr { ![file isdirectory $project_dir] }] } {
  file mkdir $project_dir
}

create_project ldpc_encoder $project_dir -part xc7z020clg400-1 -force
