#include "cachesim_row.h"

namespace dynamorio {
namespace drmemtrace {

const char *cachesim_row::create_table_string = "CREATE TABLE IF NOT EXISTS cache_stats ("
                                                "instruction_number INTEGER, "
                                                "access_address_delta INTEGER, "
                                                "pc_address_delta INTEGER, "
                                                "l1d_miss INTEGER, "
                                                "l1i_miss INTEGER, "
                                                "ll_miss INTEGER, "
                                                "instr_type TEXT, "
                                                "byte_count INTEGER, "
                                                "disassembly_string TEXT, "
                                                "current_instruction_id INTEGER, "
                                                "core INTEGER, "
                                                "thread_switch INTEGER, "
                                                "core_switch INTEGER);";

const char *cachesim_row::insert_row_string =
    "INSERT INTO cache_stats ("
    "instruction_number, "
    "access_address_delta, "
    "pc_address_delta, "
    "l1d_miss, "
    "l1i_miss, "
    "ll_miss, "
    "instr_type, "
    "byte_count, "
    "disassembly_string, "
    "current_instruction_id, "
    "core, "
    "thread_switch, "
    "core_switch"
    ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
// Setters
void
cachesim_row::set_access_address(const addr_t value)
{
    access_address = value;
}
void
cachesim_row::set_pc_address(const addr_t value)
{
    pc_address = value;
}

void
cachesim_row::set_access_address_delta(int value)
{
    access_address_delta = value;
}

void
cachesim_row::set_pc_address_delta(int value)
{
    pc_address_delta = value;
}
void
cachesim_row::set_l1d_miss(bool value)
{
    l1d_miss = value;
}
void

cachesim_row::set_l1i_miss(bool value)
{
    l1i_miss = value;
}
void

cachesim_row::set_ll_miss(bool value)
{
    ll_miss = value;
}
void
cachesim_row::set_instr_type(const std::string &value)
{
    instr_type = value;
}
void
cachesim_row::set_byte_count(uint8_t value)
{
    byte_count = value;
}
void
cachesim_row::set_disassembly_string(const std::string &value)
{
    disassembly_string = value;
}
void
cachesim_row::set_current_instruction_id(int value)
{
    current_instruction_id = value;
}
void
cachesim_row::set_core(uint8_t value)
{
    core = value;
}
void
cachesim_row::set_thread_switch(bool value)
{
    thread_switch = value;
}
void
cachesim_row::set_core_switch(bool value)
{
    core_switch = value;
}

addr_t
cachesim_row::get_access_address() const
{
    return access_address;
}
addr_t
cachesim_row::get_pc_address() const
{
    return pc_address;
}
int
cachesim_row::get_pc_address_delta() const
{
    return pc_address_delta;
}
int
cachesim_row::get_access_address_delta() const
{
    return access_address_delta;
}
bool
cachesim_row::get_l1d_miss() const
{
    return l1d_miss;
}
bool
cachesim_row::get_l1i_miss() const
{
    return l1i_miss;
}
bool
cachesim_row::get_ll_miss() const
{
    return ll_miss;
}
std::string
cachesim_row::get_instr_type() const
{
    return instr_type;
}
uint8_t
cachesim_row::get_byte_count() const
{
    return byte_count;
}
std::string
cachesim_row::get_disassembly_string() const
{
    return disassembly_string;
}
int
cachesim_row::get_current_instruction_id() const
{
    return current_instruction_id;
}
uint8_t
cachesim_row::get_core() const
{
    return core;
}
bool
cachesim_row::get_thread_switch() const
{
    return thread_switch;
}
bool
cachesim_row::get_core_switch() const
{
    return core_switch;
}

} // namespace drmemtrace
} // namespace dynamorio