module pnged_lending_protocol::pnged_lending_protocol;


use sui::sui::SUI;
use sui::coin::Coin;
use sui::event;

const LOAN_STATUS_PENDING: u8 = 0;// Loan created by borrower but not yet funded by lender
const LOAN_STATUS_ACTIVE: u8 = 1;// Loan funded by lender and active
const LOAN_STATUS_REPAID: u8 = 2;// Loan repaid by borrower and closed
const LOAN_STATUS_DEFAULTED: u8 = 3;// Loan defaulted by borrower and collateral seized by lender
const LOAN_STATUS_CANCELLED: u8 = 4;// Loan cancelled by borrower before funding

// Loan Request Event
public struct LoanRequestCreated has copy, drop{
    loan_id: address,
    borrower: address,
    principal: u64,
    interest_bps: u64,
    duration: u64,
}

// Fund Loan Event
public struct LoanFunded has copy, drop{
    loan_id: address,
    lender: address,
    principal: u64,
    borrower: address,
}

// Loan Repaid Event
public struct LoanRepaid has copy, drop{
    loan_id: address,
    borrower: address,
    lender: address,
    total_paid: u64,
}

// Loan Cancelled Event
public struct LoanCancelled has copy, drop{
    loan_id: address,
    borrower: address,
}

// Loan Liquidated Event
public struct LoanLiquidated has copy, drop{
    loan_id: address,
    lender: address,
    borrower: address,
}

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

public fun create_loan<NFT: key+store>(nft: NFT,interest_bps: u64, duration: u64,principal:u64, ctx: &mut TxContext){
   let loan=Loan {
        id: object::new(ctx),
        terms: LoanTerms {
            principal: principal,
            interest_bps: interest_bps,
            duration: duration,
        },
        borrower: ctx.sender(),
        lender:option::none(),
        nft: option::some(nft),
        start_time:0,
        loan_status: LOAN_STATUS_PENDING,
    };
   // transfer::share_object(loan);
    event::emit(LoanRequestCreated{
        loan_id: object::uid_to_address(&loan.id),
        borrower: loan.borrower,
        principal: loan.terms.principal,
        interest_bps: loan.terms.interest_bps,
        duration: loan.terms.duration,
    });
    // temporary hold until loan funded or cancelled - then loan object gets transferred to lender or nft extracted and returned to borrower respectively
    transfer::public_transfer(loan, @treasury_wallet);
}

public fun fund_loan<NFT: key+store>(loan: &mut Loan<NFT>, funds:&mut Coin<SUI>, clock: &sui::clock::Clock, ctx: &mut TxContext){
    assert!(loan.loan_status == LOAN_STATUS_PENDING);
    
    loan.lender = option::some(ctx.sender());
    loan.loan_status = LOAN_STATUS_ACTIVE;
    loan.start_time = clock.timestamp_ms();
    let protocol_fee_value = funds.value() / 100; // 1% fee
    let borrower_amount=funds.value()-protocol_fee_value;
    let protocol_coin =funds.split(protocol_fee_value, ctx);
    let borrower_coin =funds.split(borrower_amount, ctx);
    transfer::public_transfer(borrower_coin, loan.borrower);
    //protocol origination fee sent to treasury wallet
    transfer::public_transfer(protocol_coin, @treasury_wallet);

    event::emit(LoanFunded{
        loan_id: object::uid_to_address(&loan.id),
        lender: option::extract<address>(&mut loan.lender),
        principal: loan.terms.principal,
        borrower: loan.borrower,
    });
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

    event::emit(LoanRepaid{
        loan_id: object::uid_to_address(&loan.id),
        borrower: loan.borrower,
        lender: lender,
        total_paid: total_due,
    });
}

public fun liquidate<NFT: key+store>(loan: &mut Loan<NFT>,clock: &sui::clock::Clock){
    assert!(loan.loan_status == LOAN_STATUS_ACTIVE);

    let now=clock.timestamp_ms();
    assert!(now>loan.start_time+loan.terms.duration);

    let lender=option::extract<address>(&mut loan.lender);
    let nft=option::extract<NFT>(&mut loan.nft);
    transfer::public_transfer(nft, lender);

    loan.loan_status=LOAN_STATUS_DEFAULTED;

    event::emit(LoanLiquidated{
        loan_id: object::uid_to_address(&loan.id),
        lender: lender,
        borrower: loan.borrower,
    });
}

public fun cancel_loan<NFT: key+store>(loan:&mut Loan<NFT>, ctx: &mut TxContext){
    assert!(loan.loan_status == LOAN_STATUS_PENDING);
    assert!(loan.borrower == ctx.sender());

    let nft=option::extract<NFT>(&mut loan.nft);
    transfer::public_transfer(nft, loan.borrower);

    loan.loan_status=LOAN_STATUS_CANCELLED;

    event::emit(LoanCancelled{
        loan_id: object::uid_to_address(&loan.id),
        borrower: loan.borrower,
    });
}