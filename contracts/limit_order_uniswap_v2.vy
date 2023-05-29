# @version 0.3.7

struct Deposit:
    path: DynArray[address, MAX_SIZE]
    amount1: uint256
    depositor: address

enum WithdrawType:
    CANCEL
    PROFIT_TAKING
    STOP_LOSS

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view

interface WrappedEth:
    def deposit(): payable

interface UniswapV2Router:
    def WETH() -> address: pure
    def swapExactTokensForTokens(amountIn: uint256, amountOutMin: uint256, path: DynArray[address, MAX_SIZE], to: address, deadline: uint256) -> DynArray[uint256, MAX_SIZE]: nonpayable
    def swapExactTokensForETH(amountIn: uint256, amountOutMin: uint256, path: DynArray[address, MAX_SIZE], to: address, deadline: uint256) -> DynArray[uint256, MAX_SIZE]: nonpayable
    def getAmountsOut(amountIn: uint256, path: DynArray[address, MAX_SIZE]) -> DynArray[uint256, MAX_SIZE]: view

event Deposited:
    deposit_id: uint256
    token0: address
    token1: address
    amount0: uint256
    amount1: uint256
    depositor: address
    profit_taking: uint256
    stop_loss: uint256

event Withdrawn:
    deposit_id: uint256
    withdrawer: address
    withdraw_type: WithdrawType
    withdraw_amount: uint256

event UpdateCompass:
    old_compass: address
    new_compass: address

WETH: immutable(address)
VETH: constant(address) = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE # Virtual ETH
MAX_SIZE: constant(uint256) = 8
ROUTER: immutable(address)
compass: public(address)
deposit_size: public(uint256)
deposits: public(HashMap[uint256, Deposit])

@external
def __init__(_compass: address, router: address):
    self.compass = _compass
    ROUTER = router
    WETH = UniswapV2Router(ROUTER).WETH()
    log UpdateCompass(empty(address), _compass)

@internal
def _safe_approve(_token: address, _to: address, _value: uint256):
    _response: Bytes[32] = raw_call(
        _token,
        _abi_encode(_to, _value, method_id=method_id("approve(address,uint256)")),
        max_outsize=32
    )  # dev: failed approve
    if len(_response) > 0:
        assert convert(_response, bool) # dev: failed approve

@internal
def _safe_transfer_from(_token: address, _from: address, _to: address, _value: uint256):
    _response: Bytes[32] = raw_call(
        _token,
        _abi_encode(_from, _to, _value, method_id=method_id("transferFrom(address,address,uint256)")),
        max_outsize=32
    )  # dev: failed transferFrom
    if len(_response) > 0:
        assert convert(_response, bool) # dev: failed transferFrom

@external
@payable
def deposit(path: DynArray[address, MAX_SIZE], amount0: uint256, min_amount1: uint256, profit_taking: uint256, stop_loss: uint256):
    assert len(path) >= 2, "Wrong path"
    _path: DynArray[address, MAX_SIZE] = path
    token0: address = path[0]
    last_index: uint256 = unsafe_sub(len(path), 1)
    token1: address = path[last_index]
    if token0 == VETH:
        assert msg.value == amount0
        if msg.value > amount0:
            send(msg.sender, msg.value - amount0)
        WrappedEth(WETH).deposit(value=amount0)
        _path[0] = WETH
    else:
        orig_balance: uint256 = ERC20(token0).balanceOf(self)
        self._safe_transfer_from(token0, msg.sender, self, amount0)
        assert ERC20(token0).balanceOf(self) == orig_balance + amount0
    if token1 == VETH:
        _path[last_index] = WETH
    self._safe_approve(_path[0], ROUTER, amount0)
    amounts: DynArray[uint256, MAX_SIZE] = UniswapV2Router(ROUTER).swapExactTokensForTokens(amount0, min_amount1, _path, self, block.timestamp)
    assert amounts[last_index] > 0
    deposit_id: uint256 = self.deposit_size
    self.deposits[deposit_id] = Deposit({
        path: path,
        amount1: amounts[last_index],
        depositor: msg.sender
    })
    self.deposit_size = deposit_id + 1
    log Deposited(deposit_id, token0, token1, amount0, amounts[last_index], msg.sender, profit_taking, stop_loss)

@internal
def _withdraw(deposit_id: uint256, min_amount0: uint256, withdraw_type: WithdrawType):
    deposit: Deposit = self.deposits[deposit_id]
    if withdraw_type == WithdrawType.CANCEL:
        assert msg.sender == deposit.depositor
    self.deposits[deposit_id] = Deposit({
        path: empty(DynArray[address, MAX_SIZE]),
        amount1: empty(uint256),
        depositor: empty(address)
    })
    assert deposit.amount1 > 0
    last_index: uint256 = unsafe_sub(len(deposit.path), 1)
    path: DynArray[address, MAX_SIZE] = []
    for i in range(MAX_SIZE):
        path.append(deposit.path[unsafe_sub(last_index, i)])
        if i >= last_index:
            break
    if path[0] == VETH:
        path[0] = WETH
    if path[last_index] == VETH:
        path[last_index] = WETH
    self._safe_approve(path[0], ROUTER, deposit.amount1)
    amounts: DynArray[uint256, MAX_SIZE] = []
    if deposit.path[0] == VETH:
        amounts = UniswapV2Router(ROUTER).swapExactTokensForETH(deposit.amount1, min_amount0, path, deposit.depositor, block.timestamp)
    else:
        amounts = UniswapV2Router(ROUTER).swapExactTokensForTokens(deposit.amount1, min_amount0, path, deposit.depositor, block.timestamp)
    log Withdrawn(deposit_id, msg.sender, withdraw_type, amounts[last_index])

@external
def cancel(deposit_id: uint256, min_amount0: uint256):
    self._withdraw(deposit_id, min_amount0, WithdrawType.CANCEL)

@external
def withdraw(deposit_id: uint256, min_amount0: uint256, withdraw_type: WithdrawType):
    assert msg.sender == self.compass
    self._withdraw(deposit_id, min_amount0, withdraw_type)

@external
@view
def withdraw_amount(deposit_id: uint256) -> uint256:
    deposit: Deposit = self.deposits[deposit_id]
    path: DynArray[address, MAX_SIZE] = []
    last_index: uint256 = unsafe_sub(len(deposit.path), 1)
    for i in range(MAX_SIZE):
        path.append(deposit.path[unsafe_sub(last_index, i)])
        if i >= last_index:
            break
    if path[0] == VETH:
        path[0] = WETH
    if path[last_index] == VETH:
        path[last_index] = WETH
    amounts: DynArray[uint256, MAX_SIZE] = []
    amounts = UniswapV2Router(ROUTER).getAmountsOut(deposit.amount1, path)
    return amounts[last_index]

@external
def multiple_withdraw(deposit_ids: DynArray[uint256, MAX_SIZE], min_amounts0: DynArray[uint256, MAX_SIZE], withdraw_types: DynArray[WithdrawType, MAX_SIZE]):
    assert msg.sender == self.compass
    assert len(deposit_ids) == len(min_amounts0) and len(deposit_ids) == len(withdraw_types)
    for i in range(MAX_SIZE):
        if i >= len(deposit_ids):
            break
        self._withdraw(deposit_ids[i], min_amounts0[i], withdraw_types[i])

@external
def update_compass(new_compass: address):
    assert msg.sender == self.compass
    self.compass = new_compass
    log UpdateCompass(msg.sender, new_compass)
