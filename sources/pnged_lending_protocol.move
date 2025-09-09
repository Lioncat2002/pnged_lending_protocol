module pnged_lending_protocol::pnged_lending_protocol;


use sui::sui::SUI;
use sui::coin::Coin;

const LOAN_STATUS_PENDING: u8 = 0;// Loan created by borrower but not yet funded by lender
const LOAN_STATUS_ACTIVE: u8 = 1;// Loan funded by lender and active
const LOAN_STATUS_REPAID: u8 = 2;// Loan repaid by borrower and closed
const LOAN_STATUS_DEFAULTED: u8 = 3;// Loan defaulted by borrower and collateral seized by lender

public struct LoanTerms has copy, drop, store{
    principal: u64,
    interest_bps: u64,
    duration:u64,
}

public struct Loan<NFT: key+store> has key, store{
    id: UID,
    terms: LoanTerms,
    borrower: address,
    lender: option::Option<address>,
    nft: option::Option<NFT>,
    start_time: u64,
    loan_status: u8,
}

public fun create_loan<NFT: key+store>(nft: NFT, ctx: &mut TxContext){
   let loan=Loan {
        id: object::new(ctx),
        terms: LoanTerms {
            principal: 0,
            interest_bps: 0,
            duration: 0,
        },
        borrower: ctx.sender(),
        lender:option::none(),
        nft: option::some(nft),
        start_time:0,
        loan_status: LOAN_STATUS_PENDING,
    };

    transfer::public_transfer(loan, @teasury_wallet);
}

public fun fund_loan<NFT: key+store>(loan: &mut Loan<NFT>, interest_bps: u64, duration: u64,funds:&mut Coin<SUI>, clock: &sui::clock::Clock, ctx: &mut TxContext){
    assert!(loan.loan_status == LOAN_STATUS_PENDING);
    loan.terms = LoanTerms {
        principal: funds.value(),
        interest_bps,
        duration,
    };
    loan.lender = option::some(ctx.sender());
    loan.loan_status = LOAN_STATUS_ACTIVE;
    loan.start_time = clock.timestamp_ms();
    let protocol_fee_value = funds.value() / 100; // 1% fee
    let borrower_amount=funds.value()-protocol_fee_value;
    let protocol_coin =funds.split(protocol_fee_value, ctx);
    let borrower_coin =funds.split(borrower_amount, ctx);
    transfer::public_transfer(borrower_coin, loan.borrower);
    //protocol origination fee sent to treasury wallet
    transfer::public_transfer(protocol_coin, @teasury_wallet);
    //transfer::transfer(protocol_fee_value,, recipient)
}

public fun repay<NFT: key+store>(loan: &mut Loan<NFT>,mut payment:Coin<SUI>,clock: &sui::clock::Clock,ctx: &mut TxContext){
    assert!(loan.loan_status == LOAN_STATUS_ACTIVE);

    let now=clock.timestamp_ms();
    assert!(now<=loan.start_time+loan.terms.duration);

    let elapsed= now - loan.start_time;

    let total_due=loan.terms.principal + (loan.terms.principal * loan.terms.interest_bps * elapsed / 10000);
    assert!(payment.value()>=total_due);
    let payment_coin=payment.split(total_due, ctx);

    

    let lender=option::extract<address>(&mut loan.lender);
    let nft=option::extract<NFT>(&mut loan.nft);
    //transfer remaining coins back to borrower
    transfer::public_transfer(payment, loan.borrower);
    //transfer principal + interest to lender
    transfer::public_transfer(payment_coin, lender);
    //transfer nft back to borrower
    transfer::public_transfer(nft, loan.borrower);

    loan.loan_status=LOAN_STATUS_REPAID;
}

public fun liquidate<NFT: key+store>(loan: &mut Loan<NFT>,clock: &sui::clock::Clock){
    assert!(loan.loan_status == LOAN_STATUS_ACTIVE);

    let now=clock.timestamp_ms();
    assert!(now>loan.start_time+loan.terms.duration);

    let lender=option::extract<address>(&mut loan.lender);
    let nft=option::extract<NFT>(&mut loan.nft);
    transfer::public_transfer(nft, lender);

    loan.loan_status=LOAN_STATUS_DEFAULTED;
}