local _M = { _VERSION = '0.1.2' }

local bit = require "bit"
local byte = string.byte
local char = string.char
local sub = string.sub
local ngx_log = ngx.log
local ngx_exit = ngx.exit

local DEBUG = ngx.DEBUG
local ERR = ngx.ERR
local ERROR = ngx.ERROR
local OK = ngx.OK

local SUB_AUTH_VERSION = 0x01
local RSV = 0x00
local NOAUTH = 0x00
local GSSAPI = 0x01
local AUTH = 0x02
local IANA = 0x03
local RESERVED = 0x80
local NOMETHODS = 0xFF
local VERSION = 0x05
local IPV4 = 0x01
local DOMAIN_NAME = 0x03
local IPV6 = 0x04
local CONNECT = 0x01
local BIND = 0x02
local UDP = 0x03
local SUCCEEDED = 0x00
local FAILURE = 0x01
local RULESET = 0x02
local NETWORK_UNREACHABLE = 0x03
local HOST_UNREACHABLE = 0x04
local CONNECTION_REFUSED = 0x05
local TTL_EXPIRED = 0x06
local COMMAND_NOT_SUPORTED = 0x07
local ADDRESS_TYPE_NOT_SUPPORTED = 0x08
local UNASSIGNED = 0x09
local support_methods = {
    [NOAUTH]  = true,
    [AUTH] = true
}

local function send_method(sock, method)
    --
    --+----+--------+
    --|VER | METHOD |
    --+----+--------+
    --| 1  |   1    |
    --+----+--------+
    --

    local data = char(VERSION, method)

    return sock:send(data)
end

local function receive_methods(sock)
    --
    --   +----+----------+----------+
    --   |VER | NMETHODS | METHODS  |
    --   +----+----------+----------+
    --   | 1  |    1     | 1 to 255 |
    --   +----+----------+----------+
    --

    local data, err = sock:receive(2)
    if not data then
        ngx_exit(ERROR)

        return nil, err
    end

    local ver = byte(data, 1)
    local nmethods = byte(data, 2)

    local methods, err = sock:receive(nmethods)
    if not methods then
        ngx_exit(ERROR)

        return nil, err
    end

    return {
        ver= ver,
        nmethods = nmethods,
        methods = methods
    }, nil
end

local function send_replies(sock, rep, atyp, addr, port)
    --
    --+----+-----+-------+------+----------+----------+
    --|VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
    --+----+-----+-------+------+----------+----------+
    --| 1  |  1  | X'00' |  1   | Variable |    2     |
    --+----+-----+-------+------+----------+----------+
    --

    local data = {}
    data[1] = char(VERSION)
    data[2] = char(rep)
    data[3] = char(RSV)

    if atyp then
        data[4] = atyp
        data[5] = addr
        data[6] = port
    else
        data[4] = char(IPV4)
        data[5] = "\x00\x00\x00\x00"
        data[6] = "\x00\x00"
    end


    return sock:send(data)
end

local function receive_requests(sock)
    --
    -- +----+-----+-------+------+----------+----------+
    -- |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
    -- +----+-----+-------+------+----------+----------+
    -- | 1  |  1  | X'00' |  1   | Variable |    2     |
    -- +----+-----+-------+------+----------+----------+
    --

    local data, err = sock:receive(4)
    if not data then
        ngx_log(ERR, "failed to receive requests: ", err)

        return nil, err
    end

    local ver = byte(data, 1)
    local cmd = byte(data, 2)
    local rsv = byte(data, 3)
    local atyp = byte(data, 4)

    local dst_len = 0
    if atyp == IPV4 then
        dst_len = 4
    elseif atyp == DOMAIN_NAME then
        local data, err = sock:receive(1)
        if not data then
            ngx_log(ERR, "failed to receive domain name len: ", err)

            return nil, err
        end
        dst_len = byte(data, 1)
    elseif atyp == IPV6 then
        dst_len = 16
    else
        return nil, "unknow atyp " .. atyp
    end

    local data, err = sock:receive(dst_len + 2) -- port
    if err then
        ngx_log(ERR, "failed to receive DST.ADDR: ", err)

        return nil, err
    end

    local dst = sub(data, 1, dst_len)
    local port_2 = byte(data, dst_len + 1)
    local port_1 = byte(data, dst_len + 2)
    local port = port_1 + port_2 * 256

    return {
        ver = ver,
        cmd = cmd,
        rsv = rsv,
        atyp = atyp,
        addr = dst,
        port = port,
    }, nil
end

local function receive_auth(sock)
    --
    --+----+------+----------+------+----------+
    --|VER | ULEN |  UNAME   | PLEN |  PASSWD  |
    --+----+------+----------+------+----------+
    --| 1  |  1   | 1 to 255 |  1   | 1 to 255 |
    --+----+------+----------+------+----------+
    --

    local data, err = sock:receive(2)
    if err then
        return nil, err
    end

    local ver = byte(data, 1)
    local ulen = byte(data, 2)

    local data, err = sock:receive(ulen)
    if err then
        return nil, err
    end

    local uname = data

    local data, err = sock:receive(1)
    if err then
        return nil, err
    end

    local plen = byte(data, 1)

    local data, err = sock:receive(plen)
    if err then
        return nil, err
    end

    local passwd = data

    return {
        username = uname,
        password = passwd
    }, nil
end

local function send_auth_status(sock, status)
    --
    --+----+--------+
    --|VER | STATUS |
    --+----+--------+
    --| 1  |   1    |
    --+----+--------+
    --

    local data = {}

    data[1] = char(SUB_AUTH_VERSION)
    data[2] = char(status)

    return sock:send(data)
end

local function stringify_addr(atyp, addr)
    local dst
    if atyp == IPV4 then
        dst = string.format("%d.%d.%d.%d",
                byte(addr, 1),
                byte(addr, 2),
                byte(addr, 3),
                byte(addr, 4)
                )
    elseif atyp == IPV6 then
        dst = string.format("[%02X%02X:%02X%02X:%02X%02X:%02X%02X:%02X%02X:%02X%02X:%02X%02X:%02X%02X]",
                byte(addr, 1),  byte(addr, 2),
                byte(addr, 3),  byte(addr, 4),
                byte(addr, 5),  byte(addr, 6),
                byte(addr, 7),  byte(addr, 8),
                byte(addr, 9),  byte(addr, 10),
                byte(addr, 11), byte(addr, 12),
                byte(addr, 13), byte(addr, 14),
                byte(addr, 15), byte(addr, 16)
                )
    else
        return addr
    end
    return dst
end


function _M.run(timeout, username, password)
    local downsock, err = assert(ngx.req.socket(true))
    if not downsock then
        ngx_log(ERR, "failed to get the request socket: ", err)
        return ngx.exit(ERROR)
    end

    timeout = timeout or 1000
    downsock:settimeout(timeout)

    local negotiation, err = receive_methods(downsock)
    if err then
        ngx_log(ERR, "receive methods error: ", err)
        ngx_exit(ERROR)

        return
    end

    if negotiation.ver ~= VERSION then
        ngx_log(DEBUG, "only support version: ", VERSION)
        return ngx_exit(OK)
    end

    -- ignore client supported methods, we only support AUTH and NOAUTH
    -- for #i = 1, negotiation.methods + 1 then
    --     local method = byte(negotiation.methods, i)
    -- end

    local method = NOAUTH
    if username then
        method = AUTH
    end

    local ok, err = send_method(downsock, method)
    if err then
        ngx_log(ERR, "send method error: ", err)
        ngx_exit(ERROR)

        return
    end

    if username then
        local auth, err = receive_auth(downsock)
        if err then
            ngx_log(ERR, "send method error: ", err)
            ngx_exit(ERROR)

            return
        end

        local status = FAILURE
        if auth.username == username and auth.password == password then
            status = SUCCEEDED
        end

        local ok, err = send_auth_status(downsock, status)
        if err then
            ngx_log(ERR, "send auth status error: ", err)
            ngx_exit(ERROR)

            return
        end

        if status == FAILURE then
            return
        end
    end

    local requests, err = receive_requests(downsock)
    if err then
        ngx_log(ERR, "send request error: ", err)
        ngx_exit(ERROR)

        return
    end

    if requests.cmd ~= CONNECT then
        local ok, err = send_replies(downsock, COMMAND_NOT_SUPORTED)
        if err then
            ngx_log(ERR, "send replies error: ", err)
            ngx_exit(ERROR)

        end

        return
    end

    local host = stringify_addr(requests.atyp, requests.addr)
    ngx.var.upstream = host .. ":" .. requests.port


    local ok, err = send_replies(downsock, SUCCEEDED)
    if err then
        ngx_log(ERR, "send replies error: ", err)
        ngx_exit(ERROR)

        return
    end

end

return _M
