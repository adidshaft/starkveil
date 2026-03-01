document.addEventListener('DOMContentLoaded', () => {

    // 1. Splash Screen Transition
    setTimeout(() => {
        document.getElementById('splash-screen').style.opacity = '0';
        setTimeout(() => {
            document.getElementById('splash-screen').classList.add('hidden');
            document.getElementById('main-interface').classList.remove('hidden');
            document.getElementById('bottom-nav').classList.remove('hidden');
        }, 800);
    }, 2500);

    // 2. Redaction / Visibility Toggle
    const toggleBtn = document.getElementById('toggle-balance');
    const redactedElements = document.querySelectorAll('.redacted');
    let isVisible = false;

    toggleBtn.addEventListener('click', () => {
        isVisible = !isVisible;
        redactedElements.forEach(el => {
            if (isVisible) {
                el.classList.add('visible');
                // Replace text for demo
                const amountSpan = el.querySelector('span:first-child') || el.querySelector('h4');
                const fiatSpan = el.querySelector('#fiat-balance') || el.querySelector('p:not(.brand-tagline)');

                if (el.id === 'total-balance') amountSpan.innerText = '1,452.38';
                if (el.id === 'fiat-balance') el.innerText = '$2,145.89 USD';

                if (el.classList.contains('asset-balance')) {
                    if (el.parentElement.querySelector('.strk')) {
                        amountSpan.innerText = '452.38 STRK';
                        fiatSpan.innerText = '$645.89';
                    } else {
                        amountSpan.innerText = '0.015 BTC';
                        fiatSpan.innerText = '$1,500.00';
                    }
                }

                toggleBtn.innerHTML = '<i class="fa-solid fa-eye"></i>';
            } else {
                el.classList.remove('visible');

                const amountSpan = el.querySelector('span:first-child') || el.querySelector('h4');
                const fiatSpan = el.querySelector('#fiat-balance') || el.querySelector('p:not(.brand-tagline)');

                if (el.id === 'total-balance') amountSpan.innerText = '******';
                if (el.id === 'fiat-balance') el.innerText = '$****** USD';

                if (el.classList.contains('asset-balance')) {
                    amountSpan.innerText = '******';
                    if (fiatSpan) fiatSpan.innerText = '$******';
                }

                toggleBtn.innerHTML = '<i class="fa-solid fa-eye-slash"></i>';
            }
        });
    });

    // 3. Tab Switching
    const tabBtns = document.querySelectorAll('.tab-btn');
    const tabContents = document.querySelectorAll('.tab-content');

    tabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            tabBtns.forEach(b => b.classList.remove('active'));
            tabContents.forEach(c => c.classList.add('hidden'));

            btn.classList.add('active');
            document.getElementById(`tab-${btn.dataset.tab}`).classList.remove('hidden');
        });
    });

    // 4. Initial Activity Timeline
    const activityContainer = document.querySelector('.activity-timeline');
    let activities = [
        { type: 'sent', title: 'Shielded Transfer', amount: '-45.00 STRK', date: 'Today, 14:20', addr: 'Private Note (****8f2d)' },
        { type: 'shielded', title: 'Auto-Shielded', amount: '+100.00 STRK', date: 'Yesterday, 09:12', addr: 'From Public Address' }
    ];

    function renderActivities() {
        activityContainer.innerHTML = '';
        activities.forEach(act => {
            let iconClass = 'fa-arrow-right';
            let bgClass = 'sent';
            if (act.type === 'shielded') { iconClass = 'fa-shield-halved'; bgClass = 'shielded'; }
            if (act.type === 'received') { iconClass = 'fa-arrow-left'; bgClass = 'received public'; }

            const colorClass = act.amount.startsWith('+') ? 'positive' : '';

            // Render redacted amounts unless isVisible is true
            let displayAmount = '******';
            if (isVisible) {
                displayAmount = act.amount;
            }

            const html = `
                <div class="activity-item">
                    <div class="activity-icon ${bgClass}"><i class="fa-solid ${iconClass}"></i></div>
                    <div class="activity-content">
                        <div class="act-top">
                            <span class="act-title">${act.title}</span>
                            <span class="act-amount redacted ${isVisible ? 'visible' : ''} ${colorClass}">${displayAmount}</span>
                        </div>
                        <div class="act-bottom">
                            <span>${act.addr}</span>
                            <span>${act.date}</span>
                        </div>
                    </div>
                </div>
            `;
            activityContainer.innerHTML += html;
        });
    }

    // Original Render
    renderActivities();

    // Re-render activities when toggle changes to handle redaction properly
    toggleBtn.addEventListener('click', renderActivities);

    // 5. The Demo: Public Deposit -> Auto-Shield -> ZK Proof
    const demoBtn = document.getElementById('demo-trigger');
    const provingOverlay = document.getElementById('proving-overlay');
    const logsOutput = document.getElementById('proof-logs');
    const progressBar = document.getElementById('proof-progress');

    demoBtn.addEventListener('click', () => {
        // Step A: Public Deposit Arrives
        activities.unshift({
            type: 'received',
            title: 'Public Deposit Received',
            amount: '+500.00 STRK',
            date: 'Just Now',
            addr: 'From: 0x4f...8a2b'
        });
        document.querySelector('.tab-btn[data-tab="activity"]').click();
        renderActivities();

        // Step B: Auto-Shield Triggered after 2 seconds
        setTimeout(() => {
            provingOverlay.classList.remove('hidden');
            logsOutput.innerHTML = `> New public deposit detected (500 STRK).<br>> Initiating Auto-Shielding sequence...<br>`;

            let progress = 0;
            const logSteps = [
                "> Constructing local Zcash-style UTXO Note...",
                "> Computing Poseidon(value, asset_id, owner_ivk, memo)",
                "> Generating S-two STARK Proof...",
                "> Running Cairo verifier locally...",
                "> Assembling Transfer Payload...",
                "> Submitting Shielded Transaction to Sequencer...",
                "> Success: Note added to commitment tree."
            ];

            let logIndex = 0;
            const proofInterval = setInterval(() => {
                progress += Math.random() * 15;
                if (progress > 100) progress = 100;
                progressBar.style.width = `${progress}%`;

                if (logIndex < logSteps.length && progress > (logIndex * 15)) {
                    logsOutput.innerHTML += `${logSteps[logIndex]}<br>`;
                    logsOutput.scrollTop = logsOutput.scrollHeight;
                    logIndex++;
                }

                if (progress === 100) {
                    clearInterval(proofInterval);
                    setTimeout(() => {
                        provingOverlay.classList.add('hidden');

                        // Replace the public deposit with a shielded confirmation
                        activities[0] = {
                            type: 'shielded',
                            title: 'Auto-Shielded Deposit',
                            amount: '+500.00 STRK',
                            date: 'Just Now',
                            addr: 'Converted to Private Note'
                        };
                        renderActivities();
                    }, 1500);
                }
            }, 500);

        }, 2000);
    });

    // 6. Theme Toggle Logic
    const themeBtn = document.getElementById('theme-toggle');
    const root = document.documentElement;

    // Set default to Light mode manually over CSS default
    root.setAttribute('data-theme', 'light');
    themeBtn.innerHTML = '<i class="fa-solid fa-moon"></i>';

    themeBtn.addEventListener('click', () => {
        const currentTheme = root.getAttribute('data-theme');
        if (currentTheme === 'dark') {
            root.setAttribute('data-theme', 'light');
            themeBtn.innerHTML = '<i class="fa-solid fa-moon"></i>';
        } else {
            root.setAttribute('data-theme', 'dark');
            themeBtn.innerHTML = '<i class="fa-solid fa-sun"></i>';
        }
    });

});
