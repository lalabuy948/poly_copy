// Hook to flash price elements when they update
export const PriceFlash = {
  mounted() {
    this.handleEvent("price-update", ({token_id}) => {
      const element = document.querySelector(`[data-token-id="${token_id}"]`)
      if (element) {
        element.classList.add("bg-success/20")
        setTimeout(() => {
          element.classList.remove("bg-success/20")
        }, 300)
      }
    })
  },

  updated() {
    // Flash the element when it updates
    this.el.classList.add("transition-colors", "duration-300")
    this.el.classList.add("bg-success/10")
    setTimeout(() => {
      this.el.classList.remove("bg-success/10")
    }, 200)
  }
}
