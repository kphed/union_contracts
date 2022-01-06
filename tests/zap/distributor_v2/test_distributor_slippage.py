import brownie
from ...utils.merkle import OrderedMerkleTree
from brownie import interface, chain
from decimal import Decimal
from ...utils.constants import (
    CLAIM_AMOUNT,
    CVXCRV,
    CRV,
    CVX,
    CVXCRV_REWARDS,
    CURVE_CVX_ETH_POOL,
    CURVE_CVXCRV_CRV_POOL,
    CURVE_CRV_ETH_POOL,
)
from ...utils import approx


def test_distrib_zaps(
    alice, bob, charlie, dave, erin, owner, merkle_distributor_v2, vault
):
    chain.snapshot()
    cvxcrv = interface.IERC20(CVXCRV)
    crv = interface.IERC20(CRV)
    cvx = interface.IERC20(CVX)
    claimers = [owner, alice, bob, charlie, dave, erin]
    data = [{"user": claimer.address, "amount": CLAIM_AMOUNT} for claimer in claimers]
    tree = OrderedMerkleTree(data)
    merkle_distributor_v2.freeze({"from": owner})
    merkle_distributor_v2.updateMerkleRoot(tree.get_root(), True, {"from": owner})
    merkle_distributor_v2.setApprovals({"from": owner})
    withdrawal_penalty = Decimal(vault.withdrawalPenalty()) / 10000

    # test claim as cvxCrv
    proofs = tree.get_proof(alice.address)
    alice_initial_balance = cvxcrv.balanceOf(alice)

    tx = merkle_distributor_v2.claimAs(
        proofs["claim"]["index"], alice.address, CLAIM_AMOUNT, proofs["proofs"], 0, 0
    )
    assert approx(
        cvxcrv.balanceOf(alice),
        alice_initial_balance + CLAIM_AMOUNT * (1 - withdrawal_penalty),
        1e-5,
    )

    # test claim as Crv
    bob_claimable = (CLAIM_AMOUNT * vault.totalHoldings()) // vault.totalSupply()
    proofs = tree.get_proof(bob.address)
    crv_amount = interface.ICurveFactoryPool(CURVE_CVXCRV_CRV_POOL).get_dy(
        1, 0, bob_claimable * (1 - withdrawal_penalty)
    )
    bob_initial_balance = crv.balanceOf(bob)
    with brownie.reverts():
        tx = merkle_distributor_v2.claimAs(
            proofs["claim"]["index"],
            bob.address,
            CLAIM_AMOUNT,
            proofs["proofs"],
            2,
            crv_amount * 1.25,
        )
    tx = merkle_distributor_v2.claimAs(
        proofs["claim"]["index"],
        bob.address,
        CLAIM_AMOUNT,
        proofs["proofs"],
        2,
        crv_amount * 0.75,
    )
    assert approx(crv.balanceOf(bob), bob_initial_balance + crv_amount, 0.01)

    # test claim as Cvx
    proofs = tree.get_proof(charlie.address)
    charlie_claimable = (CLAIM_AMOUNT * vault.totalHoldings()) // vault.totalSupply()
    crv_amount = interface.ICurveFactoryPool(CURVE_CVXCRV_CRV_POOL).get_dy(
        1, 0, charlie_claimable * (1 - withdrawal_penalty)
    )
    eth_amount = interface.ICurveV2Pool(CURVE_CRV_ETH_POOL).get_dy(1, 0, crv_amount)
    cvx_amount = interface.ICurveV2Pool(CURVE_CVX_ETH_POOL).get_dy(0, 1, eth_amount)
    with brownie.reverts():
        tx = merkle_distributor_v2.claimAs(
            proofs["claim"]["index"],
            charlie.address,
            CLAIM_AMOUNT,
            proofs["proofs"],
            3,
            cvx_amount * 1.25,
        )
    tx = merkle_distributor_v2.claimAs(
        proofs["claim"]["index"],
        charlie.address,
        CLAIM_AMOUNT,
        proofs["proofs"],
        3,
        cvx_amount * 0.75,
    )
    assert approx(cvx.balanceOf(charlie), cvx_amount, 0.01)

    # test claim as Eth
    dave_claimable = (CLAIM_AMOUNT * vault.totalHoldings()) // vault.totalSupply()
    proofs = tree.get_proof(dave.address)
    crv_amount = interface.ICurveFactoryPool(CURVE_CVXCRV_CRV_POOL).get_dy(
        1, 0, dave_claimable * (1 - withdrawal_penalty)
    )
    eth_amount = interface.ICurveV2Pool(CURVE_CRV_ETH_POOL).get_dy(1, 0, crv_amount)
    dave_original_balance = dave.balance()
    with brownie.reverts():
        tx = merkle_distributor_v2.claimAs(
            proofs["claim"]["index"],
            dave.address,
            CLAIM_AMOUNT,
            proofs["proofs"],
            1,
            eth_amount * 1.25,
        )
    tx = merkle_distributor_v2.claimAs(
        proofs["claim"]["index"],
        dave.address,
        CLAIM_AMOUNT,
        proofs["proofs"],
        1,
        eth_amount * 0.75,
    )
    assert approx(dave.balance() - dave_original_balance, eth_amount, 0.01)

    # test claim and stake
    proofs = tree.get_proof(erin.address)
    erin_claimable = (CLAIM_AMOUNT * vault.totalHoldings()) // vault.totalSupply()
    tx = merkle_distributor_v2.claimAs(
        proofs["claim"]["index"], erin.address, CLAIM_AMOUNT, proofs["proofs"], 4, 0
    )
    assert approx(
        interface.IBasicRewards(CVXCRV_REWARDS).balanceOf(erin.address),
        erin_claimable * (1 - withdrawal_penalty),
        1e-5,
    )
    interface.IBasicRewards(CVXCRV_REWARDS).withdrawAll(False, {"from": erin})
    assert approx(
        cvxcrv.balanceOf(erin), erin_claimable * (1 - withdrawal_penalty), 1e-5
    )
    chain.revert()
