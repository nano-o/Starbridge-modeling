------------------------------ MODULE StarbridgeEthToStellar ------------------------------

\* TODO ideally, we would have a separate bridge module in which the private variables of the Stellar and Ethereum modules are not in scope
\* TODO we don't need to track balances

EXTENDS Integers, Apalache

\* @typeAlias: STELLAR_TX = [src : STELLAR_ACCNT, from : STELLAR_ACCNT, to : STELLAR_ACCNT, amount : Int, seq : Int, maxTime : Int];
\* @typeAlias: ETH_TX = [from : ETH_ACCNT, to : ETH_ACCNT, amount : Int, memo : STELLAR_ACCNT];

StellarAccountId == {"1_OF_STELLAR_ACCNT","2_OF_STELLAR_ACCNT"}
EthereumAccountId == {"1_OF_ETH_ACCNT","2_OF_ETH_ACCNT"}
Amount == 0..3
SeqNum == 0..2
Time == 0..2
WithdrawWindow == 1 \* time window the user has to execute a withdraw operation on Stellar

BridgeStellarAccountId == "1_OF_STELLAR_ACCNT"
BridgeEthereumAccountId == "1_OF_ETH_ACCNT"

VARIABLES
    \* state of Stellar and Ethereum:
    \* @type: STELLAR_ACCNT -> Int;
    stellarBalance,
    \* @type: STELLAR_ACCNT -> Int;
    stellarSeqNum,
    \* @type: Int;
    stellarTime,
    \* @type: Set(STELLAR_TX);
    stellarMempool,
    \* @type: Set(STELLAR_TX);
    stellarExecuted,
    \* @type: ETH_ACCNT -> Int;
    ethereumBalance,
    \* @type: Set(ETH_TX);
    ethereumMempool,
    \* @type: Int -> Set(ETH_TX);
    ethereumExecuted,
    \* @type: Int;
    ethereumTime,

    \* state of the bridge:
    \* @type: ETH_TX -> Bool;
    bridgeIssuedWithdrawTx,
    \* @type: ETH_TX -> STELLAR_TX;
    bridgeLastWithdrawTx,
    \* @type: Int;
    bridgeStellarTime,
    \* @type: STELLAR_ACCNT -> Int;
    bridgeStellarSeqNum,
    \* @type: Set(STELLAR_TX);
    bridgeStellarExecuted,
    \* @type: Int -> Set(ETH_TX);
    bridgeEthereumExecuted,
    \* @type: ETH_TX -> Bool;
    bridgeRefunded

ethereumVars == <<ethereumBalance, ethereumMempool, ethereumExecuted, ethereumTime>>
stellarVars == <<stellarBalance, stellarSeqNum, stellarTime, stellarMempool, stellarExecuted>>
bridgeVars == <<bridgeIssuedWithdrawTx, bridgeLastWithdrawTx, bridgeStellarTime, bridgeStellarSeqNum, bridgeStellarExecuted, bridgeEthereumExecuted, bridgeRefunded>>
bridgeChainsStateVars == <<bridgeStellarTime, bridgeStellarSeqNum, bridgeStellarExecuted, bridgeEthereumExecuted>>

Stellar == INSTANCE Stellar WITH
    AccountId <- StellarAccountId,
    BridgeAccountId <- BridgeStellarAccountId,
    balance <- stellarBalance,
    seqNum <- stellarSeqNum,
    time <- stellarTime,
    mempool <- stellarMempool,
    executed <- stellarExecuted

Ethereum == INSTANCE Ethereum WITH
    AccountId <- EthereumAccountId,
    balance <- ethereumBalance,
    mempool <- ethereumMempool,
    executed <- ethereumExecuted,
    time <- ethereumTime

Init ==
    /\  bridgeIssuedWithdrawTx = [tx \in Ethereum!Transaction |-> FALSE]
    /\  bridgeLastWithdrawTx = [tx \in Ethereum!Transaction |-> CHOOSE tx_ \in Stellar!Transaction : TRUE]
    /\  bridgeStellarTime = 0
    /\  bridgeStellarSeqNum = [a \in StellarAccountId |-> 0]
    /\  bridgeStellarExecuted = {}
    /\  bridgeEthereumExecuted = [t \in Time |-> {}]
    /\  bridgeRefunded = [tx \in Ethereum!Transaction |-> FALSE]
    /\  Stellar!Init /\ Ethereum!Init

TypeOkay ==
    /\  bridgeIssuedWithdrawTx \in [Ethereum!Transaction -> BOOLEAN]
    /\  bridgeLastWithdrawTx \in [Ethereum!Transaction -> Stellar!Transaction]
    /\  bridgeStellarTime \in Time
    /\  bridgeStellarSeqNum \in [StellarAccountId -> SeqNum]
    /\  bridgeStellarExecuted \in SUBSET Stellar!Transaction
    /\  bridgeEthereumExecuted \in [Time -> SUBSET Ethereum!Transaction]
    /\  bridgeRefunded \in [Ethereum!Transaction -> BOOLEAN]
    /\  Stellar!TypeOkay /\ Ethereum!TypeOkay

SyncWithStellar ==
    /\  bridgeStellarTime' = stellarTime
    /\  bridgeStellarSeqNum' = stellarSeqNum
    /\  bridgeStellarExecuted' = stellarExecuted
    /\  UNCHANGED <<ethereumVars, stellarVars, bridgeIssuedWithdrawTx, bridgeLastWithdrawTx, bridgeEthereumExecuted, bridgeRefunded>>

SyncWithEthereum ==
    /\  bridgeEthereumExecuted' = ethereumExecuted
    /\  UNCHANGED <<ethereumVars, stellarVars, bridgeIssuedWithdrawTx, bridgeLastWithdrawTx, bridgeStellarExecuted, bridgeStellarSeqNum, bridgeStellarTime, bridgeRefunded>>

\* A withdraw transaction is irrevocably invalid when its time bound has ellapsed or the sequence number of the receiving account is higher than the transaction's sequence number
\* @type: (STELLAR_TX) => Bool;
IrrevocablyInvalid(tx) ==
  \/  tx.maxTime < bridgeStellarTime
  \/  tx.seq < bridgeStellarSeqNum[tx.from]

BridgeEthereumExecuted == UNION {bridgeEthereumExecuted[t] : t \in Time}

\* timestamp of a transaction on Ethereum as seen by the bridge
TxTime(tx) == CHOOSE t \in Time : tx \in bridgeEthereumExecuted[t]

\* The bridge signs a new withdraw transaction when:
\* It never did so before for the same hash,
\* or the previous withdraw transaction is irrevocably invalid and the withdraw transaction has not been executed.
\* The transaction has a time bound set to WithdrawWindow ahead of the current time.
\* But what is the current time?
\* Initially it can be the time of the tx as recorded on ethereum, but what is it afterwards?
\* For now, we use previousTx.maxTime+WithdrawWindow
SignWithdrawTransaction == \E tx \in BridgeEthereumExecuted :
  /\  \neg bridgeRefunded[tx]
  /\  \/ \neg bridgeIssuedWithdrawTx[tx]
      \/ /\ \neg bridgeLastWithdrawTx[tx] \in bridgeStellarExecuted
         /\ IrrevocablyInvalid(bridgeLastWithdrawTx[tx])
  /\ \E seqNum \in SeqNum  : \* chosen by the client
      LET timeBound ==
            IF \neg bridgeIssuedWithdrawTx[tx]
              THEN TxTime(tx)+WithdrawWindow
              ELSE bridgeLastWithdrawTx[tx].time+WithdrawWindow
          withdrawTx == [
            src |-> tx.memo,
            from |-> BridgeStellarAccountId,
            to |-> tx.memo,
            amount |-> tx.amount,
            seq |-> seqNum,
            maxTime |-> timeBound]
      IN
        /\ timeBound \in Time \* for the model-checker
        /\ Stellar!ReceiveTx(withdrawTx)
        /\ bridgeIssuedWithdrawTx' = [bridgeIssuedWithdrawTx EXCEPT ![tx] = TRUE]
        /\ bridgeLastWithdrawTx' = [bridgeLastWithdrawTx EXCEPT ![tx] = withdrawTx]
  /\  UNCHANGED <<ethereumVars, bridgeChainsStateVars, bridgeRefunded>>

SignRefundTransaction == \E tx \in BridgeEthereumExecuted :
  /\  bridgeIssuedWithdrawTx[tx]
  /\  IrrevocablyInvalid(bridgeLastWithdrawTx[tx])
  /\  \neg bridgeRefunded[tx]
  /\  LET refundTx == [
        from |-> BridgeEthereumAccountId,
        to |-> tx.from,
        amount |-> tx.amount,
        memo |-> bridgeLastWithdrawTx[tx].to] \* memo is arbitrary
      IN
        Ethereum!ReceiveTx(refundTx)
  /\  bridgeRefunded' = [bridgeRefunded EXCEPT ![tx] = TRUE]
  /\  UNCHANGED <<stellarVars, bridgeIssuedWithdrawTx, bridgeLastWithdrawTx, bridgeChainsStateVars>>

UserInitiates ==
  \* a client initiates a transfer on Ethereum:
  /\ UNCHANGED <<stellarVars, bridgeVars>>
  /\ \E src \in EthereumAccountId \ {BridgeEthereumAccountId},
          x \in Amount \ {0}, dst \in StellarAccountId \ {BridgeStellarAccountId} :
       LET tx == [from |-> src, to |-> BridgeEthereumAccountId, amount |-> x, memo |-> dst]
       IN  Ethereum!ReceiveTx(tx)

Next ==
    \/  SyncWithStellar
    \/  SyncWithEthereum
    \/  UserInitiates
    \/  SignWithdrawTransaction
    \/  SignRefundTransaction
    \/ \* internal stellar transitions:
      /\ UNCHANGED <<ethereumVars, bridgeVars>>
      /\ \/  Stellar!Tick
         \/  Stellar!ExecuteTx
    \/ \* internal ethereum transitions:
      /\ UNCHANGED <<stellarVars, bridgeVars>>
      /\ \/ Ethereum!ExecuteTx
         \/ Ethereum!Tick


EthBridgeBalance == \* funds sent to the bridge on Ethereum minus refunds
  LET
    \* @type: (Int, ETH_TX) => Int;
    Step(n, tx) ==
      CASE
            tx.to = BridgeEthereumAccountId -> n + tx.amount
        []  tx.from = BridgeEthereumAccountId -> n - tx.amount
        []  OTHER -> n
  IN
    ApaFoldSet(Step, 0, Ethereum!Executed)

StellarWithdrawals ==
  LET
    \* @type: (Int, STELLAR_TX) => Int;
    Step(n, tx) ==
      IF tx.from = BridgeStellarAccountId
      THEN n + tx.amount
      ELSE n
  IN
    ApaFoldSet(Step, 0, stellarExecuted)

Inv == TypeOkay /\ Ethereum!Inv

\* Funds deposited in the bridge account always exceed or are equal to the funds taken out:
MainInvariant ==
  /\ EthBridgeBalance - StellarWithdrawals >= 0
MainInvariant_ ==
  /\ TypeOkay
  /\ Ethereum!Inv
  /\ EthBridgeBalance - StellarWithdrawals >= 0

=============================================================================
